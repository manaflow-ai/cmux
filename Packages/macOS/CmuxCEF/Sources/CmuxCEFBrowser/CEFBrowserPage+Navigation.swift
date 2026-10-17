public import CmuxBrowser
import CmuxCEF
public import Foundation

/// Back and Forward history menus: Chromium's own entries (fork API 14).
extension CEFBrowserPage: BrowserPageBackForwardListing {
    public func backForwardList() -> BrowserBackForwardList? {
        guard let list = navigationList() else { return nil }
        let entry = { (entry: CEFNavigationEntry) in
            BrowserBackForwardEntry(url: entry.url, title: entry.title, offset: entry.offset)
        }
        return BrowserBackForwardList(back: list.backEntries.map(entry), forward: list.forwardEntries.map(entry))
    }

    @discardableResult
    public func goToBackForwardEntry(offset: Int) -> Bool { goToEntry(offset: offset) }
}

/// Reopen Closed Tab: the closed page's history (``exportRestoreState()``)
/// restores in the reopened tab's new page, as cmux Next's
/// `ClosedBrowserHistories` hands it to `restoreState`.
extension CEFBrowserPage: BrowserPageNavigationRestoring {
    @discardableResult
    public func restoreNavigation(_ state: BrowserPageRestoreState) -> Bool {
        guard case .chromium(let navigation) = state, browser.restoreNavigation(navigation) else { return false }
        // A page in a pane that has never been shown starts now, as a load does.
        browser.createNow()
        return true
    }
}

/// Proceed on cmux's certificate warning in an agent-driven tab, whose
/// certificate errors the shim cancels instead of showing Chromium's
/// interstitial (cmux Next `CEFTab+CertificateWarnings.swift`).
extension CEFBrowserPage: BrowserPageCertificateBypassing {
    @discardableResult
    public func proceedPastCertificateError(_ error: ChromiumNetError, at url: URL) -> Bool {
        let host = (url.host(percentEncoded: false) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard error.isCertificateError, !host.isEmpty,
              let id = browser.browserID, let shim = shimProvider() else { return false }
        let proceed = error.certificateProceed(host: host)
        let answered = proceed.host.withCString {
            shim.certificateProceed(id, $0, Int32(clamping: error.code), proceed.chromiumDecides ? 1 : 0)
        }
        guard answered == 1 else { return false }
        browser.load(url)
        return true
    }
}
