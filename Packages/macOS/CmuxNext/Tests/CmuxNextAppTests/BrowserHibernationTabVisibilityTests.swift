import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// With `chromiumTabVisibility` each mounted Chromium page follows its tab's visibility tree node
/// (`TabContentCache.node(for:)`), so the hide reaches Chromium before the hibernation's freeze; off, no page follows
/// and the freeze works as before. The follower is the `follower` seam's recorder.
@MainActor @Suite(.serialized)
struct BrowserHibernationTabVisibilityTests {
    @Test func aMountedPageFollowsItsTabsNode() {
        let rig = Rig(follows: true)
        rig.install("a")
        let follower = rig.followers["a"]
        #expect(follower?.nodes.count == 1)
        #expect(follower?.nodes.first === rig.services.cache.node(for: "a"), "the page follows its own tab's node")
        #expect(follower?.capture(rig.services.cache.node(for: "a")) == .notCaptured)
    }

    /// A page mounted again under its tab (a hibernated page coming back, a stand-in's move) follows the same node.
    @Test func aRemountFollowsTheSameNode() throws {
        let rig = Rig(follows: true)
        rig.install("a")
        rig.hibernation.pageDidMount("a", try #require(rig.tabs["a"]))
        let nodes = rig.followers["a"]?.nodes ?? []
        #expect(nodes.count == 2)
        #expect(nodes.first === nodes.last)
    }

    @Test func withoutTheFeatureNoPageFollows() {
        let rig = Rig(follows: false)
        rig.install("a")
        #expect(rig.followers["a"]?.nodes.isEmpty == true)
    }

    /// A capture of a frozen page thaws it in the vote's turn, as Chrome's freezing policy unfreezes a page that gains
    /// a capture (freezing_policy.cc `CannotFreezeReason`). The engine refuses a freeze while the capture lasts; after
    /// it, the page freezes again.
    @Test(.timeLimit(.minutes(2))) func aCaptureThawsAFrozenPageThatFreezesAgainAfterIt() async throws {
        let rig = try FreezeRig()
        defer { rig.close() }
        let key = try await rig.hiddenPage("a")
        let node = rig.services.cache.node(for: key)
        let freezer = try #require(rig.freezers[key])
        try await rig.until("the hidden page freezes") { rig.hibernation.frozen.contains(key) }

        let capture = node.captureVote(reason: "test capture", stayHidden: true)
        #expect(!rig.hibernation.frozen.contains(key), "the capture thaws the page in the vote's turn")
        #expect(freezer.calls == [true, false])
        try await rig.until("a freeze is refused while the capture lasts") { freezer.refused > 0 }
        #expect(!rig.hibernation.frozen.contains(key))

        capture.release()
        try await rig.until("the page freezes again after the capture") { rig.hibernation.frozen.contains(key) }
        #expect(freezer.calls == [true, false, true])
    }

    /// Hidden WebKit pages that follow their node through the `follower` seam and freeze through the `freezer` seam
    /// (as `NeighborTabsWakeTests.Rig`); hidden pages freeze at once.
    @MainActor final class FreezeRig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let pane = NeighborTabsWakeTests.Pane()
        let folder: URL
        var keys: [String] = []
        var followers: [String: Follower] = [:]
        var freezers: [String: Freezer] = [:]

        init() throws {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(),
                                             deadlines: services.mainDeadlines, followsTabVisibility: true)
            services.cache.hibernation = hibernation
            hibernation.apply(BrowserHibernationSetting(mode: .off, freezeSeconds: 0.05))
            hibernation.start()
            folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("cn-tab-capture-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            hibernation.tabVisibility.follower = { [weak self] tab in self?.followers[tab.id.rawValue] }
            hibernation.freezer = { [weak self] tab in self?.freezers[tab.id.rawValue] }
        }

        /// A loaded page, installed as a tab, shown once then hidden.
        func hiddenPage(_ name: String) async throws -> String {
            let url = folder.appendingPathComponent("\(name).html")
            try "<!doctype html><title>\(name)</title><p>\(name)</p>".write(to: url, atomically: true, encoding: .utf8)
            let page = services.cache.webKit.makeWebKitTab()
            page.load(url)
            try await until("\(name) loads") {
                (try? await page.evaluate("document.readyState === 'complete' && document.title", world: .page, gesture: .agent)) == .string(name)
            }
            let key = page.id.rawValue
            followers[key] = Follower()
            freezers[key] = Freezer(node: services.cache.node(for: key))
            keys.append(key)
            services.cache.install(page, for: key)
            services.cache.present(key, by: pane, presence: .visible)
            services.cache.withdraw(key, by: pane)
            try #require(services.cache.phase(of: key) == .mountedHidden)
            return key
        }

        func until(_ what: String, _ condition: () async -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(15)
            while !(await condition()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            try #require(await condition(), "\(what) never happened")
        }

        func close() {
            for key in keys { services.cache.release(key) }
            hibernation.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Records `setFrozen` calls; refuses a freeze while its node is captured, as the Chromium tab does.
    @MainActor final class Freezer: BrowserFreezing {
        let node: VisibilityNode
        private(set) var calls: [Bool] = []
        private(set) var refused = 0

        init(node: VisibilityNode) {
            self.node = node
        }

        func setFrozen(_ frozen: Bool) -> Bool {
            if frozen, node.isCaptured {
                refused += 1
                return false
            }
            calls.append(frozen)
            return true
        }
    }

    @MainActor final class Rig {
        let services: AppServices
        let hibernation: BrowserHibernation
        let engine = MockBrowserEngine()
        var tabs: [String: MockBrowserTab] = [:]
        var followers: [String: Follower] = [:]

        init(follows: Bool) {
            _ = NSApplication.shared
            services = AppServices(environment: AppEnvironment.current([:]))
            hibernation = BrowserHibernation(cache: services.cache, memory: ManualMemoryLevelRegistry(),
                                             deadlines: services.mainDeadlines, followsTabVisibility: follows)
            services.cache.hibernation = hibernation
            hibernation.tabVisibility.follower = { [weak self] tab in self?.followers[tab.id.rawValue] }
        }

        func install(_ key: String) {
            let tab = engine.makeMockTab(BrowserTabConfiguration(id: BrowserTabID(rawValue: key)))
            tabs[key] = tab
            followers[key] = Follower()
            _ = services.cache.install(tab, for: key)
        }
    }

    /// Records the nodes it was asked to follow, and holds them as a Chromium tab does.
    @MainActor final class Follower: BrowserVisibilityFollowing {
        private(set) var nodes: [VisibilityNode] = []
        private(set) var capture: (@MainActor (VisibilityNode) -> BrowserPageCapture) = { _ in .visible }

        func followVisibility(of node: VisibilityNode, capture: @escaping @MainActor (VisibilityNode) -> BrowserPageCapture) -> Bool {
            nodes.append(node)
            self.capture = capture
            return true
        }
    }
}
