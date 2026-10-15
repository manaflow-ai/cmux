public import Foundation

/// The cmux CEF fork's extension calls, addressed by a live Chromium browser
/// id (the fork reaches a profile through one of its browsers).
///
/// ``CEFShimExtensionCalls`` forwards to the loaded shim; tests pass a fake.
/// JSON-returning calls return nil when the shim is not loaded.
@MainActor
public protocol CEFExtensionCalls: AnyObject {
    /// `cmux_cef_api_version()`; 0 while the shim is not loaded.
    var forkAPIVersion: Int32 { get }
    /// `cmux_shim_ext_list`.
    func list(browser: Int32) -> String?
    /// `cmux_shim_ext_commands`.
    func commands(browser: Int32) -> String?
    /// `cmux_shim_ext_actions` with icons of `iconPixels` square.
    func actions(browser: Int32, iconPixels: Int32) -> String?
    /// `cmux_shim_ext_set_enabled`.
    func setEnabled(browser: Int32, id: String, enabled: Bool) -> Bool
    /// `cmux_shim_ext_uninstall`.
    func uninstall(browser: Int32, id: String) -> Bool
    /// `cmux_shim_ext_reload` (fork API v5).
    func reload(browser: Int32, id: String) -> Bool
    /// `cmux_shim_ext_move_pinned` (fork API v6).
    func movePinned(browser: Int32, id: String, index: Int) -> Bool
    /// `cmux_shim_ext_set_pinned`.
    func setPinned(browser: Int32, id: String, pinned: Bool) -> Bool
    /// `cmux_shim_ext_open_options`.
    func openOptions(browser: Int32, id: String) -> Bool
    /// `cmux_shim_ext_load_unpacked`.
    func loadUnpacked(browser: Int32, path: String) -> Bool
    /// `cmux_shim_ext_command_run`.
    func runCommand(browser: Int32, id: String, command: String) -> Bool
    /// `cmux_shim_ext_action_run`: the popup hangs below `x ..< x + width` (browser view DIPs).
    func runAction(browser: Int32, id: String, x: Int32, width: Int32) -> Bool
    /// `cmux_shim_ext_action_hide_popup`.
    func hidePopup(browser: Int32, id: String)
    /// `cmux_shim_ext_action_context_menu` at a Chromium screen point (top-left origin).
    func showActionMenu(browser: Int32, id: String, x: Int32, y: Int32)
    /// `cmux_shim_install_prompt_reply`.
    func replyToPrompt(_ promptID: Int32, answer: Int32) -> Bool
    /// `cmux_shim_tab_window_id`: the Chromium window of a browser, or 0.
    func windowID(browser: Int32) -> Int32
}
