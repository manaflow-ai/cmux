import SwiftUI

struct WorkspaceContentMinimalModeSafeAreaModifier: ViewModifier {
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

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: (hasHiddenTitlebar && !isFullScreen) ? .top : [])
    }
}
