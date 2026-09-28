import SwiftUI

struct WorkspaceContentMinimalModeSafeAreaModifier: ViewModifier {
    let isFullScreen: Bool

    @WorkspaceTitlebarConfiguration private var titlebarSettings

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: (titlebarSettings.isHidden && !isFullScreen) ? .top : [])
    }
}
