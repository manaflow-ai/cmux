import SwiftUI

/// Applies the mode-dependent top padding to the window's terminal content.
/// Standard mode reserves the cmux titlebar band height; minimal mode cancels
/// any AppKit-reported safe area instead. Owning the presentation-mode
/// subscription here means a toggle re-layouts the stored content without
/// re-evaluating `ContentView` or the content subtree
/// (https://github.com/manaflow-ai/cmux/issues/5732).
struct MinimalModeContentTopPaddingBridge<Content: View>: View {
    let isFullScreen: Bool
    let titlebarPadding: CGFloat
    let hostingSafeAreaTop: CGFloat
    let content: Content

    @AppStorage(WorkspacePresentationModeSettings.modeKey)
    private var workspacePresentationMode = WorkspacePresentationModeSettings.defaultMode.rawValue

    init(
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.isFullScreen = isFullScreen
        self.titlebarPadding = titlebarPadding
        self.hostingSafeAreaTop = hostingSafeAreaTop
        self.content = content()
    }

    private var isMinimalMode: Bool {
        WorkspacePresentationModeSettings.mode(for: workspacePresentationMode) == .minimal
    }

    var body: some View {
        content
            .padding(.top, ContentView.effectiveTitlebarPadding(
                isMinimalMode: isMinimalMode,
                isFullScreen: isFullScreen,
                titlebarPadding: titlebarPadding,
                hostingSafeAreaTop: hostingSafeAreaTop
            ))
    }
}
