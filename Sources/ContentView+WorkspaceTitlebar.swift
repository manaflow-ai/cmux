import SwiftUI

extension ContentView {
    static func effectiveTitlebarPadding(
        isMinimalMode: Bool,
        showWorkspaceTitleBar: Bool = true,
        isFullScreen: Bool,
        titlebarPadding: CGFloat,
        hostingSafeAreaTop: CGFloat
    ) -> CGFloat {
        guard WorkspaceTitlebarSettings(showTitlebar: showWorkspaceTitleBar, isMinimalMode: isMinimalMode).isHidden else { return WindowChromeMetrics.appTitlebarHeight }
        guard !isFullScreen else { return 0 }
        return -max(0, min(titlebarPadding, hostingSafeAreaTop))
    }
}
