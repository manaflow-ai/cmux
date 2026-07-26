/// Temporary runtime font state owned by mobile viewport fitting.
struct MobileViewportFontFitState: Equatable {
    var baseRuntimePointSize: Float32
    var fittedRuntimePointSize: Float32

    func matchesFittedRuntimePointSize(_ runtimePointSize: Float32) -> Bool {
        abs(runtimePointSize - fittedRuntimePointSize) <= 0.05
    }

    mutating func rebase(to runtimePointSize: Float32) {
        baseRuntimePointSize = runtimePointSize
        fittedRuntimePointSize = runtimePointSize
    }

    mutating func updateDurableBase(to runtimePointSize: Float32) {
        // The state's presence records active viewport-fit ownership. Equality
        // can occur when the durable base shrinks to the fitted size; it must
        // not make a later increase escape the installed viewport constraint.
        let nextFittedRuntimePointSize =
            min(fittedRuntimePointSize, runtimePointSize)
        baseRuntimePointSize = runtimePointSize
        fittedRuntimePointSize = nextFittedRuntimePointSize
    }
}
