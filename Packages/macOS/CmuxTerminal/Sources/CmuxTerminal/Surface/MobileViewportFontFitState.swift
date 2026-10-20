/// Temporary runtime font state owned by mobile viewport fitting.
struct MobileViewportFontFitState: Equatable {
    var baseRuntimePointSize: Float32
    var fittedRuntimePointSize: Float32
    private(set) var viewportFitCeilingRuntimePointSize: Float32

    init(
        baseRuntimePointSize: Float32,
        fittedRuntimePointSize: Float32,
        viewportFitCeilingRuntimePointSize: Float32? = nil
    ) {
        self.baseRuntimePointSize = baseRuntimePointSize
        self.fittedRuntimePointSize = fittedRuntimePointSize
        self.viewportFitCeilingRuntimePointSize =
            viewportFitCeilingRuntimePointSize
            ?? fittedRuntimePointSize
    }

    func matchesFittedRuntimePointSize(_ runtimePointSize: Float32) -> Bool {
        abs(runtimePointSize - fittedRuntimePointSize) <= 0.05
    }

    mutating func rebase(to runtimePointSize: Float32) {
        baseRuntimePointSize = runtimePointSize
        fittedRuntimePointSize = runtimePointSize
        viewportFitCeilingRuntimePointSize = runtimePointSize
    }

    mutating func updateViewportFit(to runtimePointSize: Float32) {
        viewportFitCeilingRuntimePointSize = runtimePointSize
        fittedRuntimePointSize =
            min(runtimePointSize, baseRuntimePointSize)
    }

    mutating func updateDurableBase(to runtimePointSize: Float32) {
        // The state's presence records active viewport-fit ownership. Equality
        // can occur when the durable base shrinks to the fitted size; it must
        // not make a later increase escape the installed viewport constraint.
        let nextFittedRuntimePointSize =
            min(
                viewportFitCeilingRuntimePointSize,
                runtimePointSize
            )
        baseRuntimePointSize = runtimePointSize
        fittedRuntimePointSize = nextFittedRuntimePointSize
    }
}
