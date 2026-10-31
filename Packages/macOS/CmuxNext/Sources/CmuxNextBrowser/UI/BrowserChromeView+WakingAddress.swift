import Foundation

extension BrowserChromeView {
    /// Shows `asleep`'s address while this toolbar's page wakes from hibernation.
    ///
    /// A woken page is a new engine page: it reports no address (WebKit, before its restored
    /// item loads) or a blank one (Chromium is created on an empty URL so its saved history can
    /// be restored, and reports `about:blank` first) for up to a second. Without the hold the
    /// omnibar showed that blank address. The hold ends when the page reports a real address
    /// (its restored page, a redirect, a link), fails a load, or the person commits a
    /// navigation in the omnibar.
    ///
    /// - Parameter asleep: The state of the hibernated tab the page replaces (address, title,
    ///   security). A state with no address holds nothing.
    public func holdAddress(whileWaking asleep: BrowserTabState) {
        guard asleep.url != nil else { return }
        wakingAddress = asleep
        updateAddress(for: tab.state)
    }

    /// Writes the omnibar's address and lock for the page's `live` state, or the held one
    /// while the woken page has no real address yet.
    func updateAddress(for live: BrowserTabState) {
        var shown = live
        if let held = wakingAddress {
            if Self.isWakingAddress(live) { shown = held } else { wakingAddress = nil }
        }
        addressBar.update(url: Self.omnibarURL(for: shown), security: PageInfoSite.omnibarSecurity(for: shown))
    }

    /// True while a woken page has no address of its own yet: none, a blank or New Tab page, or
    /// Chromium's placeholder navigation, and no failed load whose address the omnibar shows.
    static func isWakingAddress(_ state: BrowserTabState) -> Bool {
        if state.processExit == nil, state.loadError?.failingURL != nil { return false }
        guard let url = state.url else { return true }
        if BrowserNewTabPage.isNewTabPage(url) { return true }
        return url.scheme?.lowercased() == "chrome" && url.host()?.lowercased() == "ignore"
    }
}
