import Foundation

/// The shim's `<select>` popup calls (`cmux_shim_set_popup_menus`, `cmux_shim_browser_popup_menu_reply`;
/// task 060). In process each does nothing without fork API 31; in host mode the remote shim sends
/// each as one post on the control channel.
nonisolated struct CEFShimPopupMenuOps {
    /// 1: popups come as POPUP_MENU, and Chromium shows no menu of its own.
    let setEnabled: @convention(c) (Int32) -> Void
    /// browser, token, the chosen item or -1.
    let reply: @convention(c) (Int32, Int64, Int32) -> Void

    init(_ r: CEFShimLibrary.Resolver) throws(CEFShimLibrary.LoadError) {
        setEnabled = try r("cmux_shim_set_popup_menus")
        reply = try r("cmux_shim_browser_popup_menu_reply")
    }
}

/// ``ChromiumHostPopupMenuWire`` on the runtime's shim: the remote shim in host mode, whose post reaches
/// the host's `cmux_browser_popup_menu_reply`, as `WebMenuRunner`'s choice goes back to the browser
/// process in Chrome (content/app_shim_remote_cocoa/render_widget_host_ns_view_bridge.mm).
final class CEFShimPopupMenuWire: ChromiumHostPopupMenuWire {
    private let ops: CEFShimPopupMenuOps

    init(ops: CEFShimPopupMenuOps) {
        self.ops = ops
    }

    func reply(browser: Int32, token: Int64, index: Int32) {
        ops.reply(browser, token, index)
    }
}
