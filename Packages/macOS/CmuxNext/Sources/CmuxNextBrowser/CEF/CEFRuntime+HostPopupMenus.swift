public import AppKit

/// Host mode's `<select>` popups (task 060 of plans/cmux-next/chrome-parity/p01-process.md, feature
/// `chromiumHostPopupMenus`): the Chromium Host sends each popup as data and cmux shows it as a menu
/// over the page, so the host never shows a menu of its own and never becomes the active app.
extension CEFRuntime {
    /// Fork API 31 sends `<select>` popups as data (task 171, `cmux_browser_set_popup_menu_handler`).
    static let popupMenuForkAPI: Int32 = 31

    /// Host mode, at the start (after the attach, before `cmux_shim_initialize`): the host's widgets and
    /// `<select>` popups in cmux, as the source asks. `forkAPIVersion` is the host's fork's.
    func showHostNativeUI(_ shim: CEFShimLibrary, forkAPIVersion: Int32) {
        showHostWidgets(shim)
        showHostPopupMenus(shim, forkAPIVersion: forkAPIVersion)
    }

    /// Host mode, at the start: turns the host's popups into POPUP_MENU events and shows them when the
    /// source asks for it (``CEFHostStart/drawsPopupMenus``) and the host's fork has the handler. Without
    /// it Chromium shows its own menu, as before. Sent before `cmux_shim_initialize`, so the first
    /// browser gets the handler too, and a restarted host gets it again from the remote shim's replay log.
    func showHostPopupMenus(_ shim: CEFShimLibrary, forkAPIVersion: Int32) {
        guard let hostStart, hostStart.drawsPopupMenus, forkAPIVersion >= Self.popupMenuForkAPI else { return }
        showHostPopupMenus(on: CEFShimPopupMenuWire(ops: shim.popupMenus))
        shim.popupMenus.setEnabled(1)
    }

    /// Shows the host's popups over the page views of this runtime's tabs, their answers going to `wire`.
    func showHostPopupMenus(on wire: any ChromiumHostPopupMenuWire) {
        hostStart?.popupMenus = ChromiumHostPopupMenus(wire: wire, pageView: { [weak self] browser in
            self?.popupMenuView(of: browser)
        })
    }

    /// POPUP_MENU: shows it as a cmux menu. A popup with no cmux menus to show it (the source did not ask,
    /// or POPUP_MENU from a host this runtime did not turn popups on in) closes as a cancel, so the page
    /// never waits.
    func popupMenuOpened(browser: Int32, token: Int64, popup: ChromiumHostPopupMenu?) {
        if let menus = hostStart?.popupMenus { return menus.show(browser: browser, token: token, popup: popup) }
        shim?.popupMenus.reply(browser, token, -1)
    }

    /// The view that shows `browser`'s page: its pane's page view while the pane shows that tab.
    private func popupMenuView(of browser: Int32) -> NSView? {
        guard let host = tabsByBrowser[browser]?.host, host.visibleTab?.browserID == browser else { return nil }
        return host.hostedPageView
    }
}

extension CEFEngine {
    /// Host mode shows `<select>` popups as cmux menus (feature `chromiumHostPopupMenus` with a host at fork
    /// API 31; `debug.cef` `host_popup_menus`).
    public var drawsHostPopupMenus: Bool { CEFRuntime.shared.hostStart?.popupMenus != nil }
    /// The host's `<select>` menu while it tracks (`debug.menu`), nil while none is open.
    public var hostPopupMenu: NSMenu? { CEFRuntime.shared.hostStart?.popupMenus?.presentedMenu }
}
