import SwiftUI

struct MinimalModeTitlebarEventSurfaceLayer: View {
    let isFullScreen: Bool

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    @AppStorage(WorkspaceTitlebarSettings.showTitlebarKey)
    private var showWorkspaceTitlebar = WorkspaceTitlebarSettings.defaultShowTitlebar

    private var hasHiddenTitlebar: Bool {
        WorkspaceTitlebarSettings.isHidden(
            showTitlebar: showWorkspaceTitlebar,
            presentationMode: workspacePresentationMode
        )
    }

    var body: some View {
        MinimalModeTitlebarEventSurfaceView(isEnabled: hasHiddenTitlebar && !isFullScreen)
    }
}
