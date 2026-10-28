@testable import CmuxNextPages
import Foundation
import Testing
import WebKit

/// cmux pages share web content processes, at most ``WebProcessGroups/pagesPerProcess`` pages per
/// process (plans/cmux-next/sequoia-lag.md, plans/cmux-next/chrome-parity/p07-memory.md 087). Before,
/// every page started its own process: 55 tabs made 54 WebContent processes, 3.8 to 4.5 GB, in the
/// Tart stress on macOS 14, 15 and 26.
@MainActor
struct WebProcessGroupsTests {
    private let agent = PageDescriptor(id: "test.groups-agent", resource: "groups-agent", processGroup: .agent, namespaces: [])
    private let privileged = PageDescriptor(id: "test.groups-privileged", resource: "groups-privileged", processGroup: .privileged, namespaces: [])
    private let viewer = PageDescriptor(id: "test.groups-viewer", resource: "groups-viewer", processGroup: .viewer, namespaces: [])
    private let solo = PageDescriptor(id: "test.groups-solo", resource: "groups-solo", processGroup: .solo, namespaces: [])
    private let secrets = PageDescriptor(id: "test.groups-secrets", resource: "groups-secrets", processGroup: .secrets, namespaces: [])
    private let asks = PageEngineOptions(sharesWebKitProcess: true)
    private let membership = WebProcessGroups.Membership.group(.agent)

    @Test func pagesJoinTheFirstPageOfTheirGroupUntilItIsFull() {
        let groups = WebProcessGroups(pagesPerProcess: 3)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        var views: [WKWebView] = []
        var related: [WKWebView?] = []
        for _ in 0..<5 {
            views.append(Self.make(groups, Self.configuration(pool, store), as: membership))
            related.append(Self.related(views.last!))
        }
        #expect(related[0] == nil)
        #expect(related[1] === views[0])
        #expect(related[2] === views[0])
        // The fourth page starts the next group; the fifth joins it.
        #expect(related[3] == nil)
        #expect(related[4] === views[3])
    }

    /// The size comes from the memory budget the composition root passes (`SubsystemBudget.webProcessPagesPerGroup`);
    /// a size below one still lets each page start its own process.
    @Test func theGroupSizeIsTheOneGivenAndAtLeastOne() {
        #expect(WebProcessGroups(pagesPerProcess: 8).pagesPerProcess == 8)
        #expect(WebProcessGroups(pagesPerProcess: 0).pagesPerProcess == 1)
        let single = WebProcessGroups(pagesPerProcess: 1)
        let pool = WKProcessPool(), store = WKWebsiteDataStore.nonPersistent()
        let first = Self.make(single, Self.configuration(pool, store), as: membership)
        let second = Self.make(single, Self.configuration(pool, store), as: membership)
        #expect(Self.related(second) == nil)
        withExtendedLifetime(first) {}
    }

    /// A page of another data store or pool starts a group of its own, and the first group goes on:
    /// the next page of the first store still joins the first page.
    @Test func aPageWithAnotherDataStoreOrPoolStartsItsOwnGroupAndKeepsTheFirst() {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        let first = Self.make(groups, Self.configuration(pool, store), as: membership)
        let otherStore = Self.make(groups, Self.configuration(pool, .nonPersistent()), as: membership)
        let otherPool = Self.make(groups, Self.configuration(WKProcessPool(), otherStore.configuration.websiteDataStore), as: membership)
        let again = Self.make(groups, Self.configuration(pool, store), as: membership)
        let otherStoreAgain = Self.make(groups, Self.configuration(pool, otherStore.configuration.websiteDataStore), as: membership)
        #expect(Self.related(otherStore) == nil)
        #expect(Self.related(otherPool) == nil)
        #expect(Self.related(again) === first)
        #expect(Self.related(otherStoreAgain) === otherStore)
    }

    /// Pages of different capability groups never share a process, as Chromium keeps their renderers apart.
    @Test func pagesOfAnotherGroupStartTheirOwn() {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool(), store = WKWebsiteDataStore.nonPersistent()
        let first = Self.make(groups, Self.configuration(pool, store), as: .group(.privileged))
        let ofViewer = Self.make(groups, Self.configuration(pool, store), as: .group(.viewer))
        let ofSolo = Self.make(groups, Self.configuration(pool, store), as: .page(solo.id))
        let second = Self.make(groups, Self.configuration(pool, store), as: .group(.privileged))
        #expect(Self.related(ofViewer) == nil)
        #expect(Self.related(ofSolo) == nil)
        #expect(Self.related(second) === first)
    }

    /// One in-memory store per group for the app's life: a group's pages share it,
    /// so their localStorage, and a page of another group or a solo page that asks gets another.
    @Test func eachGroupHasOneDataStoreOfItsOwn() {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let agentStore = groups.dataStore(for: .group(.agent))
        let privilegedStore = groups.dataStore(for: .group(.privileged))
        #expect(groups.dataStore(for: .group(.agent)) === agentStore)
        #expect(groups.dataStore(for: .group(.privileged)) === privilegedStore)
        #expect(privilegedStore !== agentStore)
        #expect(groups.dataStore(for: .group(.viewer)) !== agentStore)
        #expect(groups.dataStore(for: .page(solo.id)) !== agentStore)
        #expect(groups.dataStore(for: .page(solo.id)) !== privilegedStore)
    }

    @Test func aClosedFirstPageStartsANewGroup() {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        // The first page goes away (its last reference ends with the pool).
        autoreleasepool {
            _ = Self.make(groups, Self.configuration(pool, store), as: membership)
        }
        let next = Self.make(groups, Self.configuration(pool, store), as: membership)
        #expect(Self.related(next) == nil)
    }

    /// Off (`webKitPageProcessGroups`), only a page that asks shares; on, every page of a sharing group
    /// does. A solo page shares only with its own instances and only when it asks; a secrets page never.
    @Test(arguments: [false, true])
    func whichPagesJoinAGroup(everySharingPage: Bool) {
        let groups = WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: everySharingPage)
        #expect(groups.membership(of: agent, options: asks) == .group(.agent))
        #expect(groups.membership(of: privileged, options: asks) == .group(.privileged))
        #expect(groups.membership(of: solo, options: asks) == .page(solo.id))
        #expect(groups.membership(of: secrets, options: asks) == nil)
        let unasked: [WebProcessGroups.Membership?] = [agent, privileged, viewer, solo, secrets].map {
            groups.membership(of: $0, options: .standard)
        }
        let expected: [WebProcessGroups.Membership?] = everySharingPage
            ? [.group(.agent), .group(.privileged), .group(.viewer), nil, nil]
            : [nil, nil, nil, nil, nil]
        #expect(unasked == expected)
    }

    /// The point of the grouping, observed in WebKit: two grouped pages that loaded run in one process.
    @Test func groupedPagesRunInOneWebContentProcess() async throws {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        let a = Self.make(groups, Self.configuration(pool, store), as: membership)
        let b = Self.make(groups, Self.configuration(pool, store), as: membership)
        try await Self.load(a)
        try await Self.load(b)
        let pidA = try #require(a.value(forKey: "_webProcessIdentifier") as? Int32)
        let pidB = try #require(b.value(forKey: "_webProcessIdentifier") as? Int32)
        #expect(pidA != 0)
        #expect(pidA == pidB)
    }

    /// A crash of the shared process reaches every page of the group, so each one reloads or waits
    /// for its show (``PageCrashRecovery``; PageCrashGroupTests covers the reloads and the shared budget).
    @Test(.timeLimit(.minutes(1)))
    func aCrashOfTheSharedProcessReachesEveryPageOfTheGroup() async throws {
        let groups = WebProcessGroups(pagesPerProcess: 8)
        let pool = WKProcessPool()
        let store = WKWebsiteDataStore.nonPersistent()
        let views = [Self.make(groups, Self.configuration(pool, store), as: membership),
                     Self.make(groups, Self.configuration(pool, store), as: membership)]
        for view in views { try await Self.load(view) }
        let pid = try #require(views[0].value(forKey: "_webProcessIdentifier") as? Int32)
        #expect(views[1].value(forKey: "_webProcessIdentifier") as? Int32 == pid)
        let watchers = views.map { TerminationWatcher($0) }
        #expect(kill(pid, SIGKILL) == 0)
        for watcher in watchers { await watcher.terminated() }
    }

    private static func make(_ groups: WebProcessGroups, _ configuration: WKWebViewConfiguration,
                             as membership: WebProcessGroups.Membership) -> WKWebView {
        groups.webView(for: configuration, as: membership) { WKWebView(frame: .zero, configuration: $0) }
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

/// Returns once WebKit told the view its web content process ended.
@MainActor
private final class TerminationWatcher: NSObject, WKNavigationDelegate {
    private var didTerminate = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(_ view: WKWebView) {
        super.init()
        view.navigationDelegate = self
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        didTerminate = true
        waiter?.resume()
        waiter = nil
    }

    func terminated() async {
        guard !didTerminate else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
