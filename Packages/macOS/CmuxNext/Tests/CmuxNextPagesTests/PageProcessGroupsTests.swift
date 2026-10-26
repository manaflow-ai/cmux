import CmuxNextCompat
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Foundation
import Testing
import WebKit

/// Pages share web content processes within their ``PageProcessGroup``, at most
/// ``PageProcessGroups/pagesPerProcess`` pages per process, in one store per group and one pool
/// (plans/cmux-next/chrome-parity/p13-webui.md 3.B, task 015). Before, every page made its own
/// non-persistent store and so its own process; agent pages without groups made 55 tabs cost 54
/// WebContent processes, 3.8 to 4.5 GB, in the Tart stress on macOS 14, 15 and 26.
@MainActor
struct PageProcessGroupsTests {
    private static let privilegedA = PageDescriptor(id: "test.groups-a", resource: "groups-a", processGroup: .privileged, namespaces: [])
    private static let privilegedB = PageDescriptor(id: "test.groups-b", resource: "groups-b", processGroup: .privileged, namespaces: [])
    private static let viewer = PageDescriptor(id: "test.groups-viewer", resource: "groups-viewer", processGroup: .viewer, namespaces: [])
    private static let secrets = PageDescriptor(id: "test.groups-secrets", resource: "groups-secrets", processGroup: .secrets, namespaces: [])

    @Test func theNinthViewOfAGroupStartsANewAnchor() {
        let groups = WebUIHost.makeProcessGroups()
        #expect(groups.pagesPerProcess == 8)
        let views = (0..<10).map { _ in Self.make(groups, .agent) }
        #expect(Self.related(views[0]) == nil)
        for view in views[1..<8] { #expect(Self.related(view) === views[0]) }
        // The ninth view starts the next process; the tenth joins it.
        #expect(Self.related(views[8]) == nil)
        #expect(Self.related(views[9]) === views[8])
    }

    @Test func eachGroupMakesOneStoreAndEveryViewIsInOnePool() {
        var made = 0
        let pool = WKProcessPool()
        let groups = PageProcessGroups(processPool: pool, relatedGroups: [.agent],
                                       sharedStoreGroups: Set(PageProcessGroup.allCases)) {
            made += 1
            return WKWebsiteDataStore.nonPersistent()
        }
        for group in PageProcessGroup.allCases {
            #expect(groups.dataStore(for: group) === groups.dataStore(for: group))
        }
        #expect(made == PageProcessGroup.allCases.count)
        #expect(groups.dataStore(for: .privileged) !== groups.dataStore(for: .viewer))
        let configuration = WKWebViewConfiguration()
        groups.configure(configuration, for: .secrets)
        #expect(configuration.processPool === pool)
        #expect(configuration.websiteDataStore === groups.dataStore(for: .secrets))
    }

    @Test func secretsAndSoloPagesAreNeverRelated() {
        let shared = WebUIHost.makeProcessGroups(sharesPageGroups: true)
        let forced = PageProcessGroups(processPool: WKProcessPool(), relatedGroups: Set(PageProcessGroup.allCases),
                                       sharedStoreGroups: []) {
            WKWebsiteDataStore.nonPersistent()
        }
        #expect(!forced.relatedGroups.contains(.secrets))
        #expect(!forced.relatedGroups.contains(.solo))
        // A related group always shares its store: WebKit relates views only in one store.
        #expect(forced.sharedStoreGroups == forced.relatedGroups)
        for groups in [shared, forced] {
            for group in [PageProcessGroup.secrets, .solo] {
                let first = Self.make(groups, group)
                let second = Self.make(groups, group)
                #expect(Self.related(first) == nil)
                #expect(Self.related(second) == nil)
            }
        }
    }

    @Test func privilegedAndViewerPagesShareOnlyWithTheFeature() {
        let off = WebUIHost.makeProcessGroups()
        let on = WebUIHost.makeProcessGroups(sharesPageGroups: true)
        for group in [PageProcessGroup.privileged, .viewer] {
            _ = Self.make(off, group)
            #expect(Self.related(Self.make(off, group)) == nil)
            let anchor = Self.make(on, group)
            #expect(Self.related(Self.make(on, group)) === anchor)
        }
    }

    /// Without the feature only agent pages share a store, as before the groups: two viewer pages
    /// (diff, markdown) keep their own localStorage, freed when each closes.
    @Test func withoutTheFeatureOnlyAgentPagesShareAStore() {
        let off = WebUIHost.makeProcessGroups()
        #expect(off.sharedStoreGroups == [.agent])
        #expect(off.dataStore(for: .agent) === off.dataStore(for: .agent))
        for group in PageProcessGroup.allCases where group != .agent {
            #expect(off.dataStore(for: group) !== off.dataStore(for: group))
        }
        let on = WebUIHost.makeProcessGroups(sharesPageGroups: true)
        for group in PageProcessGroup.allCases {
            #expect(on.dataStore(for: group) === on.dataStore(for: group))
        }
    }

    /// A pooled spare made for Settings (`solo`) may show History or Cloud (`privileged`) only while
    /// neither group shares a store; with the feature its store is not theirs.
    @Test func aSpareShowsAnotherGroupsPageOnlyWhenNeitherSharesAStore() {
        let off = WebUIHost.makeProcessGroups()
        #expect(off.mayShow(PageDescriptor.history.processGroup, inViewMadeFor: PageDescriptor.settings.processGroup))
        #expect(!off.mayShow(.agent, inViewMadeFor: .solo))
        let on = WebUIHost.makeProcessGroups(sharesPageGroups: true)
        #expect(!on.mayShow(PageDescriptor.history.processGroup, inViewMadeFor: PageDescriptor.settings.processGroup))
        #expect(on.mayShow(.solo, inViewMadeFor: .solo))
    }

    /// The spare is made in the groups the pool was given (the app's), so it relates and anchors
    /// there, not in groups of its own.
    @Test func aPooledSpareIsMadeInThePoolsGroups() throws {
        // The built Settings page wins when bundled; otherwise this root serves it (first registration wins).
        PageID.registerBundledRoot(try Self.pageRoot(), for: PageDescriptor.settings.id)
        let groups = WebUIHost.makeProcessGroups(sharesPageGroups: true)
        let recipe = try #require(PageWebView.pooledHostRecipe(.settings, processGroups: groups))
        #expect(recipe.processGroups === groups)
        #expect(recipe.configuration.websiteDataStore === groups.dataStore(for: .solo))
        let spare = PageWebView(recipe: recipe)
        defer { spare.close() }
        #expect(spare.madeForGroup == .solo)
        #expect(spare.webView.configuration.processPool === groups.processPool)
    }

    @Test func aViewNeverJoinsAnotherGroupsAnchor() {
        let groups = WebUIHost.makeProcessGroups(sharesPageGroups: true)
        let agent = Self.make(groups, .agent)
        let privileged = Self.make(groups, .privileged)
        let viewer = Self.make(groups, .viewer)
        #expect(Self.related(privileged) == nil)
        #expect(Self.related(viewer) == nil)
        #expect(Self.related(Self.make(groups, .agent)) === agent)
    }

    @Test func aClosedAnchorStartsANewGroup() {
        let groups = WebUIHost.makeProcessGroups()
        // The first page goes away (its last reference ends with the pool).
        autoreleasepool { _ = Self.make(groups, .agent) }
        #expect(Self.related(Self.make(groups, .agent)) == nil)
    }

    /// A Chromium page's web view never loads, so it neither relates (that would start the group's
    /// web content process) nor becomes the group's anchor.
    @Test func aChromiumPageDoesNotTakePartInItsGroup() throws {
        let root = try Self.pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(FakeChromiumHosting())
        let chromium = try #require(host.open(PageOpenRequest(descriptor: Self.privilegedA, root: root, routes: [])))
        #expect(chromium.engineDecision == .chromium)
        #expect(Self.related(chromium.webView) == nil)
        let webKit = Self.make(host.processGroups, .privileged)
        #expect(Self.related(webKit) == nil)
        #expect(Self.related(Self.make(host.processGroups, .privileged)) === webKit)
        host.close(chromium)
    }

    /// The point of the groups, observed in WebKit: two different pages of one group that loaded
    /// run in one web content process, a page of another group in another one, and a secrets page
    /// in its own.
    @Test func pagesOfOneGroupRunInOneWebContentProcess() async throws {
        let root = try Self.pageRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = Self.host(nil)
        let opened = try [Self.privilegedA, Self.privilegedB, Self.viewer, Self.secrets, Self.secrets].map { descriptor in
            try #require(host.open(PageOpenRequest(descriptor: descriptor, root: root, routes: [])))
        }
        defer { opened.forEach(host.close) }
        for view in opened {
            #expect(view.engineDecision.engine == .webKit)
            await view.waitUntilLoaded()
        }
        let pids = try opened.map { try #require($0.webView.value(forKey: "_webProcessIdentifier") as? Int32) }
        #expect(pids.allSatisfy { $0 != 0 })
        #expect(pids[0] == pids[1], "two privileged pages share a process")
        #expect(pids[2] != pids[0], "a viewer page is not in the privileged process")
        #expect(pids[3] != pids[0] && pids[3] != pids[2], "a secrets page shares with no other group")
        #expect(pids[4] != pids[3], "a secrets page shares with no other page")
    }

    private static func host(_ chromium: (any PageChromiumHosting)?) -> WebUIHost {
        WebUIHost(chromium: chromium, openPanel: nil,
                  memory: QuietMemoryRegistry(), clock: PageTestClock.never, sharesPageGroups: true)
    }

    private static func pageRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("page-groups-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
        return root
    }

    private static func make(_ groups: PageProcessGroups, _ group: PageProcessGroup) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        groups.configure(configuration, for: group)
        return groups.webView(for: group, configuration: configuration, joins: true) { WKWebView(frame: .zero, configuration: $0) }
    }

    private static func related(_ view: WKWebView) -> WKWebView? {
        view.configuration.value(forKey: "_relatedWebView") as? WKWebView
    }
}
