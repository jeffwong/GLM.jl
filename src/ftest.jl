type FTestResult{N}
    ssr::NTuple{N, Float64}
    dof::NTuple{N, Int}
    dof_resid::NTuple{N, Int}
    r2::NTuple{N, Float64}
    fstat::Tuple{Vararg{Float64}}
    pval::Tuple{Vararg{PValue}}
end

"""A helper function to determine if mod1 is nested in mod2"""
function issubmodel(mod1::LinPredModel, mod2::LinPredModel)
    mod1.rr.y != mod2.rr.y && return false # Response variables must be equal

    # Now, test that all predictor variables are equal
    pred1 = mod1.pp.X
    npreds1 = size(pred1, 2)
    pred2 = mod2.pp.X
    npreds2 = size(pred1, 2)
    # If model 1 has more predictors, it can't possibly be a submodel
    npreds1 > npreds2 && return false 

    @inbounds for i in 1:npreds1
        var_in_mod2 = false
        for j in 1:npreds2
            if view(pred1, :, i) == view(pred2, :, j)
                var_in_mod2 = true
                break
            end
        end

        if !var_in_mod2 # We have found a predictor variable in model 1 that is not in model 2
            return false 
        end
    end

    return true
end

_diffn{N, T}(t::NTuple{N, T}) = ntuple(i->t[i]-t[i+1], N-1)

_diff{N, T}(t::NTuple{N, T}) = ntuple(i->t[i+1]-t[i], N-1)

dividetuples{N}(t1::NTuple{N}, t2::NTuple{N}) = ntuple(i->t1[i]/t2[i], N)

"""
    ftest(mod::LinearModel...)

For each sequential pair of linear predictors in `mod`, perform an F-test to determine if 
the first one fits significantly better than the next.

A table is returned containing residual degrees of freedom (DOF), degrees of freedom,
difference in DOF from the preceding model, sum of squared residuals (SSR), difference in
SSR from the preceding model, R², difference in R² from the preceding model, and F-statistic
and p-value for the comparison between the two models.

!!! note
    This function can be used to perform an ANOVA by testing the relative fit of two models
    to the data

# Examples

Suppose we want to compare the effects of two or more treatments on some result. Because
this is an ANOVA, our null hypothesis is that `Result~1` fits the data as well as
`Result~Treatment`.
 
```jldoctest
julia> dat = DataFrame(Treatment=[1, 1, 1, 2, 2, 2, 1, 1, 1, 2, 2, 2.],
                       Result=[1.1, 1.2, 1, 2.2, 1.9, 2, .9, 1, 1, 2.2, 2, 2]);

julia> mod = lm(@formula(Result~Treatment), dat);

julia> nullmod = lm(@formula(Result~1), dat);

julia> ft = ftest(mod.model, nullmod.model)
        Res. DOF DOF ΔDOF    SSR    ΔSSR      R²    ΔR²       F* p(>F)
Model 1       10   3      0.1283          0.9603                      
Model 2       11   2   -1 3.2292 -3.1008 -0.0000 0.9603 241.6234 <1e-7
"""
function ftest(mods::LinearModel...)
    nmodels = length(mods)
    for i in 2:nmodels
        issubmodel(mods[i], mods[i-1]) || 
        throw(ArgumentError("F test $i is only valid if model $i is nested in model $(i-1)"))
    end

    SSR = deviance.(mods)

    nparams = dof.(mods)

    df2 = _diffn(nparams)
    df1 = Int.(dof_residual.(mods))

    MSR1 = dividetuples(_diff(SSR), df2)
    MSR2 = dividetuples(SSR, df1)[1:nmodels-1]

    fstat = dividetuples(MSR1, MSR2)
    pval = PValue.(ccdf.(FDist.(df2, df1[1:nmodels-1]), fstat))
    return FTestResult(SSR, nparams, df1, r2.(mods), fstat, pval)
end

function show{N}(io::IO, ftr::FTestResult{N})
    Δdof = _diffn(ftr.dof_resid)
    Δssr = _diffn(ftr.ssr)
    ΔR² = _diffn(ftr.r2)

    nc = 10
    nr = N
    outrows = Matrix{String}(nr+1, nc)
    
    outrows[1, :] = ["", "Res. DOF", "DOF", "ΔDOF", "SSR", "ΔSSR",
                     "R²", "ΔR²", "F*", "p(>F)"]

    outrows[2, :] = ["Model 1", @sprintf("%.0d", ftr.dof_resid[1]),
                     @sprintf("%.0d", ftr.dof[1]), " ",
                     @sprintf("%.4f", ftr.ssr[1]), " ",
                     @sprintf("%.4f", ftr.r2[1]), " ", " ", " "]
    
    for i in 2:nr
        outrows[i+1, :] = ["Model $i", @sprintf("%.0d", ftr.dof_resid[i]),
                           @sprintf("%.0d", ftr.dof[i]), @sprintf("%.0d", Δdof[i-1]),
                           @sprintf("%.4f", ftr.ssr[i]), @sprintf("%.4f", Δssr[i-1]),
                           @sprintf("%.4f", ftr.r2[i]), @sprintf("%.4f", ΔR²[i-1]),
                           @sprintf("%.4f", ftr.fstat[i-1]), string(ftr.pval[i-1]) ]
    end
    colwidths = length.(outrows)
    max_colwidths = [maximum(view(colwidths, :, i)) for i in 1:nc]

    for r in 1:nr+1
        for c in 1:nc
            cur_cell = outrows[r, c]
            cur_cell_len = length(cur_cell)
            
            padding = " "^(max_colwidths[c]-cur_cell_len)
            if c > 1 
                padding = " "*padding
            end
            
            print(io, padding)
            print(io, cur_cell)
        end
        print(io, "\n")
    end
end
