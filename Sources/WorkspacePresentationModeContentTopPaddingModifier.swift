import SwiftUI

struct WorkspacePresentationModeContentTopPaddingModifier: ViewModifier {
    let isFullScreen: Bool
    let runtimeCache: WorkspacePresentationModeRuntimeCache

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    func body(content: Content) -> some View {
        content.padding(.top, ContentView.effectiveTitlebarPadding(
            isMinimalMode: isMinimalMode,
            isFullScreen: isFullScreen,
            titlebarPadding: runtimeCache.titlebarPadding,
            hostingSafeAreaTop: runtimeCache.hostingSafeAreaTop
        ))
    }
}
