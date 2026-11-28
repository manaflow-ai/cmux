import Foundation

/// A hidden Chromium page frozen through the page lifecycle: its timers, tasks and rendering stop
/// until it thaws. On cmux14 this cut a hidden renderer's energy by about 90 %.
///
/// From fork API 29 through `WebContents::SetPageFrozen` (`cmux_shim_tab_set_frozen`), which opens
/// no DevTools session, so the tab's renderer stays shareable; it freezes hidden pages only.
/// Before, through DevTools `Page.setWebLifecycleState`.
extension CEFTab: BrowserFreezing {
    @discardableResult
    public func setFrozen(_ frozen: Bool) -> Bool {
        guard let browserID, !isClosed, let shim = runtime.shim else { return false }
        // In the tab's DevTools call order (`CEFDevToolsCallOrder`): now when no call waits, else right after the
        // last one, so a script still encoding never runs on a page frozen after it was called, and an agent call
        // made right after a thaw never reaches a frozen page.
        if runtime.forkFeatures.rendererPaths, let setFrozen = shim.tabSetFrozen {
            return runtime.devToolsOrder.post(browserID) { setFrozen(browserID, frozen ? 1 : 0) == 1 }
        }
        // No one waits for the reply (the runtime drops a reply without a waiter).
        return runtime.postDevTools(browserID, method: "Page.setWebLifecycleState", params: ["state": frozen ? "frozen" : "active"])
    }

    /// An enabled extension of the tab's profile can script its web page (Bitwarden's passkey scripts:
    /// two live copies after a frozen worker restart failed every sign-in).
    public var freezeDropsExtensionEvents: Bool {
        runtime.extensionStores.scriptsPage(at: state.url, profile: profileID)
    }

    /// Freezes a page that is never shown (the spare window's about:blank placeholder) through DevTools
    /// `Page.setWebLifecycleState`, which hides it to Chromium first (`WasHidden`): the fork's
    /// `cmux_shim_tab_set_frozen` freezes only pages Chromium already counts hidden, and
    /// `CefBrowserHost::WasHidden` does nothing for a windowed Chrome-style browser. Unfrozen, the
    /// placeholder counted visible and ran rAF at ~98/s at idle (fleet probe 4e065838, macOS 27). It is
    /// thawed only when a cmux page takes it as its own browser (`CEFPaneHost.adoptPlaceholder`); otherwise a
    /// take closes it on the next turn (`CEFPaneHost.closeSparePlaceholder`).
    /// Freezes the spare placeholder only after its initial navigation has settled. Freezing a page
    /// mid-load can leave Chromium's TabIcon compositor animation running in its GPU process.
    func freezeNeverShownPageIfReady() {
        guard host.freezesPlaceholder, host.placeholder === self,
              let browserID, !isClosed, isLoadingSettled, !host.placeholderFrozen else { return }
        host.placeholderFrozen = true
        freezeNeverShownPage(browserID)
    }

    private func freezeNeverShownPage(_ browser: Int32) {
        runtime.postDevTools(browser, method: "Page.setWebLifecycleState", params: ["state": "frozen"])
    }
}
