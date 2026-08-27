import SwiftUI

struct WorkspacePresentationModeContentTopPaddingModifier: ViewModifier {
    let isFullScreen: Bool
    let titlebarPadding: CGFloat
    let hostingSafeAreaTop: CGFloat

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    func body(content: Content) -> some View {
        content.padding(.top, ContentView.effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            titlebarPadding: titlebarPadding,
            hostingSafeAreaTop: hostingSafeAreaTop
        ))
    }
}
