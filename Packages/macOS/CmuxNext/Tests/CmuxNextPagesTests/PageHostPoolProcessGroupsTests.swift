import AppKit
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import Testing
import WebKit

/// With `webKitPageProcessGroups` a pooled page of a sharing group (History, Cloud: `privileged`) never
/// takes the spare, which has a process and a store of its own: it opens through ``WebUIHost/open(_:)``
/// and joins its group's WebContent process (p07-memory-087). Settings, a `solo` page, still takes it.
@MainActor @Suite(.serialized) struct PageHostPoolProcessGroupsTests {
    /// Off, every pooled page may take the spare; on, only the pages that join no group.
    @Test(arguments: [false, true])
    func theSpareServesOnlyPagesOfNoGroup(everySharingPage: Bool) {
        let memory = PageTestMemory()
        let groups = WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: everySharingPage)
        let pool = PageHostPool(memory: memory.coordinator, activity: { 0 }, isTrackingMenu: { false },
                                processGroups: groups)
        defer { pool.dropSpare() }
        #expect(pool.spareServes(.settings, options: .standard))
        #expect(pool.spareServes(.history, options: .standard) == !everySharingPage)
        #expect(pool.spareServes(.cloud, options: .standard) == !everySharingPage)
        #expect(!pool.spareServes(.history, options: PageEngineOptions(sharesWebKitProcess: true)))
        #expect(!pool.spareServes(.settings, options: PageEngineOptions(sharesWebKitProcess: true)))
    }

    /// A refused grouped open is not a show the spare could serve: it arms no spare build
    /// (`pageRendererAtFirstShow`); a Settings open does.
    @Test func aGroupedOpenArmsNoSpare() {
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let memory = PageTestMemory()
        let pool = PageHostPool(memory: memory.coordinator, policy: PageHostPool.Policy(preloadOnMakeVisible: true),
                                deadlines: LifecycleDeadlineRig.never, activity: { 0 }, isTrackingMenu: { false },
                                processGroups: WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: true))
        defer { pool.dropSpare() }
        pool.follow(window)
        pool.noteLikely()
        #expect(pool.claim(.history, routes: [], window: window) == nil)
        #expect(pool.claim(.cloud, routes: [], window: window) == nil)
        #expect(!pool.shouldBuild, "a grouped page, which never takes the spare, armed one")
        #expect(pool.claim(.settings, routes: [], window: window) == nil, "no spare to claim yet")
        #expect(pool.shouldBuild, "a shown Settings page arms the next spare")
    }

    /// The app's open of History (claim, else ``WebUIHost/open(_:)``, as `PageFactory` does) with a ready
    /// spare: the spare stays parked and History is related to the open Cloud page, in the groups' store.
    /// A Settings claim then takes that spare, which is in no group.
    @Test func aClaimedHistoryJoinsTheOpenPrivilegedPageAndSettingsTakesTheSpare() async throws {
        let memory = PageTestMemory()
        let window = PageHostPoolLaunchWindowTests.shownWindow()
        defer { window.close() }
        let groups = WebProcessGroups(pagesPerProcess: 8, groupsEverySharingPage: true)
        var policy = PageHostPool.Policy()
        policy.idleInput = .milliseconds(5)
        let pool = PageHostPool(memory: memory.coordinator, policy: policy, activity: { 0 }, isTrackingMenu: { false },
                                processGroups: groups)
        defer { pool.dropSpare() }
        let host = WebUIHost(chromium: nil, openPanel: nil, memory: QuietMemoryRegistry(), deadlines: LifecycleDeadlineRig.never,
                             processGroups: groups)
        await Self.waitForSpare(pool, in: window)
        let spare = try #require(pool.spareHost)
        let cloud = try #require(host.open(PageOpenRequest(descriptor: .cloud, routes: [])))

        let history = try #require(pool.claim(.history, routes: [], window: window, focus: false)
            ?? host.open(PageOpenRequest(descriptor: .history, routes: [])))
        #expect(history !== spare, "History took the spare, a process outside its group")
        #expect(pool.spareHost === spare && pool.isSpareReady)
        #expect(history.webView.configuration.value(forKey: "_relatedWebView") as? WKWebView === cloud.webView)
        #expect(history.webView.configuration.websiteDataStore === groups.dataStore)
        #expect(history.crash.sharesWebKitProcess)

        let settings = try #require(pool.claim(.settings, routes: [], window: window, focus: false))
        #expect(settings === spare)
        #expect(settings.webView.configuration.websiteDataStore !== groups.dataStore, "Settings got a grouped spare")
        #expect(settings.webView.configuration.value(forKey: "_relatedWebView") == nil)
        pool.release(settings)
        for view in [cloud, history] { host.close(view) }
    }

    private static func waitForSpare(_ pool: PageHostPool, in window: NSWindow) async {
        if pool.target == nil { pool.follow(window) }
        pool.noteLikely()
        if !pool.isSpareReady {
            _ = await PageTestWait.value("spare ready") { (done: @escaping (Bool) -> Void) in
                pool.onSpareReady = { _ in done(true) }
            }
        }
    }
}
