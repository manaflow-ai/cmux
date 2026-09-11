import AppKit
import Foundation

#if DEBUG
extension TerminalController {
    /// `debug.sidebar.cloud_popover` `{show?: bool, window_id?: uuid}`: toggles
    /// (or forces) the sidebar footer's Cloud Workspaces popover in the addressed
    /// main window (default: the key window) and reports the resulting state.
    /// `enabled` is the Cloud Machines beta gate; the button is not mounted
    /// while it is off, so `presented` stays false then.
    nonisolated func v2DebugSidebarCloudPopover(params: [String: Any]) -> V2CallResult {
        let show = Self.surfaceBool(params["show"])
        let windowID = (params["window_id"] as? String).flatMap(UUID.init(uuidString:))
        return v2MainSync {
            var targetWindow: NSWindow?
            if let windowID {
                guard let window = AppDelegate.shared?.mainWindow(for: windowID) else {
                    return .err(code: "not_found", message: "window not found", data: nil)
                }
                targetWindow = window
            }
            var userInfo: [String: Any] = [:]
            if let show { userInfo["show"] = show }
            NotificationCenter.default.post(name: .sidebarCloudWorkspacesPopoverRequested, object: targetWindow, userInfo: userInfo)
            return .ok([
                "enabled": CloudMachinesFeature.isEnabled,
                "presented": SidebarCloudWorkspacesPopoverPresence.isPresented,
            ])
        }
    }
}
#endif
