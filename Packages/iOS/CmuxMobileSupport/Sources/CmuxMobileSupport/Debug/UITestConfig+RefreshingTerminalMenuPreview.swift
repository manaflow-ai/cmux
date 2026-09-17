import Foundation

/// Debug-only UI-test preview flags isolated from the production config surface.
extension UITestConfig {
    /// Whether the workspace detail terminal-picker refresh preview is enabled.
    ///
    /// When `CMUX_UITEST_WORKSPACE_DETAIL_REFRESHING_TERMINAL_MENU=1`, the root
    /// view renders a connected workspace shell already opened to a workspace
    /// with many terminals, then repeatedly refreshes terminal titles without
    /// changing terminal identity or order. DEBUG-only.
    public static var workspaceDetailRefreshingTerminalMenuPreviewEnabled: Bool {
        workspaceDetailRefreshingTerminalMenuPreviewEnabled(from: ProcessInfo.processInfo.environment)
    }

    static func workspaceDetailRefreshingTerminalMenuPreviewEnabled(from env: [String: String]) -> Bool {
        #if DEBUG
        return env["CMUX_UITEST_WORKSPACE_DETAIL_REFRESHING_TERMINAL_MENU"] == "1"
        #else
        return false
        #endif
    }
}
