import SwiftUI

/// Hosts the minimal-mode titlebar event surface (drag/double-click routing
/// behind the chrome) with its own presentation-mode subscription, so the
/// window-root `ContentView` body does not observe the mode
/// (https://github.com/manaflow-ai/cmux/issues/5732).
struct MinimalModeTitlebarEventSurfaceHost: View {
    let isFullScreen: Bool

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        MinimalModeTitlebarEventSurfaceView(isEnabled: isMinimalMode && !isFullScreen)
    }
}
