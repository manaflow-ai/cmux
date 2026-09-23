import SwiftUI

struct WorkspacePresentationModeContentTopPaddingModifier: ViewModifier {
    let isFullScreen: Bool
    let runtimeCache: WorkspacePresentationModeRuntimeCache

    @WorkspaceTitlebarConfiguration private var titlebarSettings

    func body(content: Content) -> some View {
        content.padding(.top, ContentView.effectiveTitlebarPadding(
            isMinimalMode: titlebarSettings.isMinimalMode,
            showWorkspaceTitleBar: titlebarSettings.showTitlebar,
            isFullScreen: isFullScreen,
            titlebarPadding: runtimeCache.titlebarPadding,
            hostingSafeAreaTop: runtimeCache.hostingSafeAreaTop
        ))
    }
}
