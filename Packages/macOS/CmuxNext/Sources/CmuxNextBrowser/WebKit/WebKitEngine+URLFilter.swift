import Foundation

extension WebKitEngine {
    /// Shows cmux's error page for a page the organization's URL blocklist
    /// refused, as Chromium shows ERR_BLOCKED_BY_ADMINISTRATOR.
    func showBlockedByOrganization(_ url: URL, in tab: WebKitTab) {
        let id = tab.allocateNavigationID()
        tab.apply(.started(id, url: url))
        let error = ChromiumNetError(code: ChromiumNetError.blockedByAdministrator, text: "net::ERR_BLOCKED_BY_ADMINISTRATOR")
        tab.apply(.failed(id, error.loadError(failingURL: url, engineShowsPage: false)))
    }
}
