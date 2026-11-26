import SwiftUI

struct WorkspaceContentMinimalModeSafeAreaModifier: ViewModifier {
    let isFullScreen: Bool

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
    }
}
