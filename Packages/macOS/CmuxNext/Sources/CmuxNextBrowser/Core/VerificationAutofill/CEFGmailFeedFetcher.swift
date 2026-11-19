public import Foundation

/// Fetches Gmail's inbox feed through a live Chromium tab's request context
/// (``CEFRuntime/profileFetch(_:url:maxBytes:)``): the Google sign-in the person already has in
/// that browser profile goes with the request inside Chromium, and the cookies never reach Swift
/// or a page. The tab is the page that waits for a code, so the feed is read in that page's
/// profile (plans/cmux-next/email-verification-autofill/DESIGN.md "Gmail in cmux's browser").
public nonisolated struct CEFGmailFeedFetcher: GmailFeedFetching {
    /// Why a fetch could not run.
    public enum Failure: Error, Sendable, Hashable {
        /// No live Chromium tab to fetch through (a WebKit tab waits, or the tab closed).
        case noChromiumTab
        /// The network request failed or the shim has no profile fetch.
        case fetchFailed
    }

    /// The feed is small (Gmail lists at most 20 entries); a larger body is not a feed.
    static let maxBytes = 512 * 1024

    private let tab: @MainActor @Sendable () -> (any BrowserTab)?

    /// - Parameter tab: The tab to fetch through: a waiting page's Chromium tab.
    public init(tab: @escaping @MainActor @Sendable () -> (any BrowserTab)?) {
        self.tab = tab
    }

    public func feed(accountIndex: Int) async throws -> Data? {
        try await Self.fetch(tab: tab, accountIndex: accountIndex)
    }

    @MainActor private static func fetch(tab: @MainActor () -> (any BrowserTab)?, accountIndex: Int) async throws -> Data? {
        guard let cef = tab() as? CEFTab, let browser = cef.browserID else { throw Failure.noChromiumTab }
        guard let url = URL(string: "https://mail.google.com/mail/u/\(accountIndex)/feed/atom") else { return nil }
        guard let result = await cef.runtime.profileFetch(browser, url: url, maxBytes: maxBytes) else { throw Failure.fetchFailed }
        // 401: no Google sign-in in this slot; a redirect (stopped): not a feed.
        return result.status == 200 ? result.body : nil
    }
}
