final class WorkspacePresentationModeRuntimeCache {
    // Mutated only from ContentView's main-thread SwiftUI/AppKit callbacks; this
    // is intentionally not observable because mode changes must not invalidate
    // ContentView itself.
    var titlebarSettings: WorkspaceTitlebarSettings
    var isMinimalMode: Bool { titlebarSettings.isMinimalMode }

    init(titlebarSettings: WorkspaceTitlebarSettings = WorkspaceTitlebarSettings()) {
        self.titlebarSettings = titlebarSettings
    }
}
