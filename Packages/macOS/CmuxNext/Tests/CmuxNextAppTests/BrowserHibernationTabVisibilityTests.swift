import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-212: with `chromiumTabVisibility` each mounted Chromium page follows its tab's visibility tree node
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
            hibernation.follower = { [weak self] tab in self?.followers[tab.id.rawValue] }
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
