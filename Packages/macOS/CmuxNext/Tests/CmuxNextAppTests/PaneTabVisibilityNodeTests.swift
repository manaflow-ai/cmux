import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// The pane and tab nodes of the visibility tree (p06-scheduler.md B). A tab is
/// visible when it is selected in a visible pane; a pane is hidden while suspended (its workspace
/// draws nothing). A selection flips both tabs in its own turn, and each subscriber hears one flip.
@MainActor struct PaneTabVisibilityNodeTests {
    final class Provider: InternalPageProvider {
        let page = InternalPageID(rawValue: "visibility-node-test")
        var title: String { "Notes" }
        var symbol: String { "doc" }
        func makeView(for key: String, in window: WindowController?) -> NSView { NSView() }
    }

    /// Records every flip a node tells its subscribers.
    final class Flips {
        private(set) var values: [Visibility] = []
        private var tokens: [VisibilitySubscription] = []
        func watch(_ node: VisibilityNode) {
            tokens.append(node.subscribe(owner: "PaneTabVisibilityNodeTests") { [weak self] in self?.values.append($0) })
        }
    }

    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "~")])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w1", screens: [screen])])
    }

    private static func connected() throws -> DaemonIdentity {
        let json = #"{"app":"cmux-tui","protocol":1,"session":"visibility-node-test","generation":"g1"}"#
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// A pane outside a workspace (its node is a root) with two page tabs, the first selected. The
    /// pane holds its window state weakly: the caller keeps it.
    private static func pane() throws -> (AppServices, WindowState, PaneController, a: String, b: String) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.daemon.store
        store.connectionState = .connected(try connected())
        store.apply(snapshot: tree())
        let model = try #require(store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let provider = Provider()
        services.pages.register(provider)
        let state = WindowState(record: record)
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services, state: state)
        let a = services.pages.open(provider.page, in: pane.paneKey, of: store)
        let b = services.pages.open(provider.page, in: pane.paneKey, of: store)
        pane.syncStripFromStore()
        pane.applySelection(StripTabID(a))
        return (services, state, pane, a, b)
    }

    @Test func selectingBFlipsAHiddenAndBVisibleInTheSameTurn() throws {
        let (services, state, pane, a, b) = try Self.pane()
        defer { withExtendedLifetime((services, state)) { pane.teardown() } }
        let nodeA = services.cache.node(for: a), nodeB = services.cache.node(for: b)
        #expect(nodeA.isVisible && nodeB.effective == .hidden, "before: A \(nodeA.effective), B \(nodeB.effective)")
        let flipsA = Flips(), flipsB = Flips()
        flipsA.watch(nodeA)
        flipsB.watch(nodeB)

        pane.applySelection(StripTabID(b))

        #expect(nodeA.effective == .hidden && nodeB.isVisible, "after: A \(nodeA.effective), B \(nodeB.effective)")
        #expect(flipsA.values == [.hidden] && flipsB.values == [.visible],
                "one notification each: A \(flipsA.values), B \(flipsB.values)")
        #expect(services.cache.node(for: b) === nodeB, "the cache keeps the node the pane selects")
    }

    @Test func aSuspendedPaneHidesItsSelectedTabAndSelectionsWhileSuspendedFlipNothing() throws {
        let (services, state, pane, a, b) = try Self.pane()
        defer { withExtendedLifetime((services, state)) { pane.teardown() } }
        let nodeA = services.cache.node(for: a), nodeB = services.cache.node(for: b)
        let flipsA = Flips(), flipsB = Flips()
        flipsA.watch(nodeA)
        flipsB.watch(nodeB)

        pane.suspend()
        #expect(pane.visibilityNode.effective == .hidden && nodeA.effective == .hidden)
        #expect(flipsA.values == [.hidden] && flipsB.values.isEmpty)

        for _ in 0..<10 {
            pane.applySelection(StripTabID(b))
            pane.applySelection(StripTabID(a))
        }
        pane.applySelection(StripTabID(b))
        #expect(flipsA.values == [.hidden] && flipsB.values.isEmpty,
                "selections in a suspended pane flipped tabs: A \(flipsA.values), B \(flipsB.values)")

        pane.resume()
        #expect(pane.visibilityNode.isVisible && nodeB.isVisible && nodeA.effective == .hidden)
        #expect(flipsA.values == [.hidden] && flipsB.values == [.visible],
                "resume shows only the tab selected now: A \(flipsA.values), B \(flipsB.values)")
    }

    @Test func aTabNoPaneSelectsIsHiddenAndTeardownHidesTheSelectedTab() throws {
        let (services, state, pane, a, _) = try Self.pane()
        defer { withExtendedLifetime((services, state)) {} }
        #expect(services.cache.node(for: "tab-nobody-selects").effective == .hidden)
        let nodeA = services.cache.node(for: a)
        #expect(nodeA.isVisible)
        pane.teardown()
        #expect(nodeA.effective == .hidden, "a torn-down pane's selected tab stays visible")
    }
}
