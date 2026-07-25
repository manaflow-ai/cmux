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
        let wasTemporarilyFitted =
            fittedRuntimePointSize < baseRuntimePointSize - 0.05
        let nextFittedRuntimePointSize = wasTemporarilyFitted
            ? min(fittedRuntimePointSize, runtimePointSize)
            : runtimePointSize
        baseRuntimePointSize = runtimePointSize
        fittedRuntimePointSize = nextFittedRuntimePointSize
    }
}
