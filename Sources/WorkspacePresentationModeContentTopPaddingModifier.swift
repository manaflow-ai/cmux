import SwiftUI

struct WorkspacePresentationModeContentTopPaddingModifier: ViewModifier {
    let isFullScreen: Bool
    let runtimeCache: WorkspacePresentationModeRuntimeCache

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
        content.padding(.top, ContentView.effectiveTitlebarPadding(
            isMinimalMode: hasHiddenTitlebar,
            isFullScreen: isFullScreen,
            titlebarPadding: runtimeCache.titlebarPadding,
            hostingSafeAreaTop: runtimeCache.hostingSafeAreaTop
        ))
    }
}
