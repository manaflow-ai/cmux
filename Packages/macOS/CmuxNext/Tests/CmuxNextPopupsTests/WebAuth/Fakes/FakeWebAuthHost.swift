import CmuxNextBrowser
@testable import CmuxNextPopups
import Foundation
import Observation

/// The app side of a sign-in window: mock Chromium pages and a record of
/// the links out. Observable, so a test waits for a page to arrive.
@Observable
final class FakeWebAuthHost: WebAuthHost {
    /// When set, no page is made: `makeSignInPage` throws it.
    @ObservationIgnored var failure: (any Error)?
    /// When true, `makeSignInPage` waits for ``releasePages()`` (a page that
    /// arrives after its window ended).
    @ObservationIgnored var holdsPages = false
    private(set) var configurations: [BrowserTabConfiguration] = []
    private(set) var pages: [MockBrowserTab] = []
    private(set) var links: [URL] = []
    /// Page requests waiting for ``releasePages()``.
    private(set) var waiting = 0
    @ObservationIgnored private var held: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private let engine = MockBrowserEngine(kind: .cef)

    func makeSignInPage(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        configurations.append(configuration)
        if holdsPages {
            waiting += 1
            await withCheckedContinuation { held.append($0) }
        }
        if let failure { throw failure }
        let page = engine.makeMockTab(configuration)
        pages.append(page)
        return page
    }

    func openSignInLink(_ url: URL) { links.append(url) }

    /// Lets every held page request go on.
    func releasePages() {
        let released = held
        held = []
        waiting = 0
        for request in released { request.resume() }
    }
}
