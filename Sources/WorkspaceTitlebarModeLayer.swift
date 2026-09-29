import SwiftUI

struct WorkspaceTitlebarModeLayer<Titlebar: View>: View {
    let titlebar: () -> Titlebar

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
        if !hasHiddenTitlebar {
            titlebar()
        }
    }
}
