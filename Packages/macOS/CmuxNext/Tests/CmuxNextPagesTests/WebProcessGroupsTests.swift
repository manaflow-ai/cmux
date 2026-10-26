@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// New Tab and agent pages share web content processes, at most ``WebProcessGroups/pagesPerProcess``
/// pages per process (plans/cmux-next/sequoia-lag.md). Before, every page started its own process:
/// 55 tabs made 54 WebContent processes, 3.8 to 4.5 GB, in the Tart stress on macOS 14, 15 and 26.
@MainActor
struct WebProcessGroupsTests {
    @Test func pagesJoinTheFirstPageOfTheirGroupUntilItIsFull() {
        let groups = WebProcessGroups(pagesPerProcess: 3)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        var views: [WKWebView] = []
        var related: [WKWebView?] = []
        for _ in 0..<5 {
            let configuration = Self.configuration(pool, store)
            views.append(groups.webView(for: configuration) { WKWebView(frame: .zero, configuration: $0) })
            related.append(Self.related(views.last!))
        }
        #expect(related[0] == nil)
        #expect(related[1] === views[0])
        #expect(related[2] === views[0])
        // The fourth page starts the next group; the fifth joins it.
        #expect(related[3] == nil)
        #expect(related[4] === views[3])
    }

    @Test func aPageWithAnotherDataStoreOrPoolStartsItsOwnGroup() {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool()
        let first = groups.webView(for: Self.configuration(pool, .nonPersistent())) { WKWebView(frame: .zero, configuration: $0) }
        let otherStore = groups.webView(for: Self.configuration(pool, .nonPersistent())) { WKWebView(frame: .zero, configuration: $0) }
        let otherPool = groups.webView(for: Self.configuration(WKProcessPool(), otherStore.configuration.websiteDataStore)) {
            WKWebView(frame: .zero, configuration: $0)
        }
        #expect(Self.related(otherStore) == nil)
        #expect(Self.related(otherPool) == nil)
        _ = first
    }

    @Test func aClosedFirstPageStartsANewGroup() {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        // The first page goes away (its last reference ends with the pool).
        autoreleasepool {
            _ = groups.webView(for: Self.configuration(pool, store)) { WKWebView(frame: .zero, configuration: $0) }
        }
        let next = groups.webView(for: Self.configuration(pool, store)) { WKWebView(frame: .zero, configuration: $0) }
        #expect(Self.related(next) == nil)
    }

    /// The point of the grouping, observed in WebKit: two grouped pages that loaded run in one process.
    @Test func groupedPagesRunInOneWebContentProcess() async throws {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        let a = groups.webView(for: Self.configuration(pool, store)) { WKWebView(frame: .zero, configuration: $0) }
        let b = groups.webView(for: Self.configuration(pool, store)) { WKWebView(frame: .zero, configuration: $0) }
        try await Self.load(a)
        try await Self.load(b)
        let pidA = try #require(a.value(forKey: "_webProcessIdentifier") as? Int32)
        let pidB = try #require(b.value(forKey: "_webProcessIdentifier") as? Int32)
        #expect(pidA != 0)
        #expect(pidA == pidB)
    }

    private static func configuration(_ pool: WKProcessPool, _ store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = pool
        configuration.websiteDataStore = store
        return configuration
    }

    private static func related(_ view: WKWebView) -> WKWebView? {
        view.configuration.value(forKey: "_relatedWebView") as? WKWebView
    }

    /// Loads a small page into `view` and returns when its navigation finished.
    private static func load(_ view: WKWebView) async throws {
        let delegate = NavigationWaiter()
        view.navigationDelegate = delegate
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            delegate.continuation = continuation
            view.loadHTMLString("<!doctype html><title>t</title>", baseURL: URL(string: "about:blank"))
        }
        view.navigationDelegate = nil
    }
}

/// Resumes once when the page's navigation finished or failed.
@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, any Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
