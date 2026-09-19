import SwiftUI

struct WorkspacePresentationModeContentTopPaddingModifier: ViewModifier {
    let isFullScreen: Bool
    let titlebarPadding: CGFloat
    let hostingSafeAreaTop: CGFloat

    @WorkspaceTitlebarConfiguration private var titlebarSettings

    func body(content: Content) -> some View {
        content.padding(.top, ContentView.effectiveTitlebarPadding(
            isMinimalMode: titlebarSettings.isMinimalMode,
            showWorkspaceTitleBar: titlebarSettings.showTitlebar,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        ))
    }
}
