final class WorkspacePresentationModeRuntimeCache {
    // Mutated only from main-thread AppKit callbacks; this
    // is intentionally not observable because mode changes must not invalidate
    // ContentView itself.
    var isMinimalMode: Bool

    init(isMinimalMode: Bool = WorkspacePresentationModeSettings.isMinimal()) {
        self.isMinimalMode = isMinimalMode
    }
}
