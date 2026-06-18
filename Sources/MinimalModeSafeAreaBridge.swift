import SwiftUI

/// Applies the minimal-mode top safe-area cancellation to a workspace's
/// content subtree while owning the presentation-mode subscription
/// (https://github.com/manaflow-ai/cmux/issues/5732). On a toggle only this
/// wrapper's body re-runs; `content` is the stored view value from the
/// workspace body, so SwiftUI skips its body and just re-layouts instead of
/// rebuilding the whole Bonsplit tree.
struct MinimalModeSafeAreaBridge<Content: View>: View {
    let isFullScreen: Bool
    let content: Content

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    init(isFullScreen: Bool, @ViewBuilder content: () -> Content) {
        self.isFullScreen = isFullScreen
        self.content = content()
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        content
            .ignoresSafeArea(.container, edges: (isMinimalMode && !isFullScreen) ? .top : [])
    }
}
