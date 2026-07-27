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
}
