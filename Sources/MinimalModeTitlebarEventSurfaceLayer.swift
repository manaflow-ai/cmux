import SwiftUI

struct MinimalModeTitlebarEventSurfaceLayer: View {
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
