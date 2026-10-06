import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Testing

/// The app wiring of the location trail (plans/cmux-next/history.md 4.2):
/// a window's settled focus records a location, Go Back focuses the earlier
/// tab through the registry action, and the focus it causes is absorbed.
/// Closing a workspace lists it under closed history. Windows never go on
/// screen.
@MainActor
struct LocationTrailWiringTests {
    static let key = "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a07"

    static func tree(tabs: [Int], workspaces: Bool = true) throws -> DaemonTree {
        guard workspaces else { return DaemonTree(workspaceRevision: 3, workspaces: []) }
        let tabJSON = tabs.map { #"{"kind":"pty","name":"t\#($0)","surface":\#($0),"dead":false,"cwd":"/tmp/t\#($0)"}"# }
        let json = """
        {"generation":"g1","workspace_revision":2,"workspaces":[{"active":true,"id":1,"key":"\(key)","name":"proj",
        "screens":[{"active":true,"id":2,"layout":{"pane":3,"type":"leaf"},"name":null,"panes":[{"active_tab":0,"id":3,"name":null,
        "tabs":[\(tabJSON.joined(separator: ","))]}]}]}]}
        """
        return try JSONDecoder().decode(DaemonTree.self, from: Data(json.utf8))
    }

    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
    }

    @Test func settledFocusRecordsAndGoBackReturnsToTheEarlierTab() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        services.daemon.store.apply(snapshot: try Self.tree(tabs: [7, 8]))
        let controller = try #require(services.windows.openWindow(workspaces: [Self.key]))
        services.windows.reconcileMembership()
        defer { controller.window?.close() }
        let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let (first, second) = (pane.tabs[0].id, pane.tabs[1].id)
        let trail = services.locationTrail
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        trail.now = { clock }

        await Self.settle { controller.focus.state.topology.contains(pane: pane.id) }
        controller.focus.send(.selectTab(pane: pane.id, tab: first, workspace: Self.key, source: .mouse))
        await Self.settle { trail.trail.current?.location.key.tab == first }
        clock += 5
        controller.focus.send(.selectTab(pane: pane.id, tab: second, workspace: Self.key, source: .mouse))
        await Self.settle { trail.trail.entries.count >= 2 }
        #expect(trail.trail.entries.map(\.location.key.tab) == [first, second])

        clock += 5
        #expect(services.registry.perform("focusHistoryBack"))
        await Self.settle { controller.focus.state.pane.flatMap { controller.focus.state.topology.pane($0)?.selected } == first }
        let focus = controller.focus.state
        #expect(focus.pane.flatMap { focus.topology.pane($0)?.selected } == first)
        // The Back's own focus change is absorbed: no new entry.
        #expect(trail.trail.entries.map(\.location.key.tab) == [first, second])
        #expect(trail.trail.current?.location.key.tab == first)
        #expect(trail.trail.canGoForward(isAvailable: trail.isAvailable))
        // Boundary activation is a silent no-op for keyboard and menu callers.
        #expect(services.registry.perform("focusHistoryForward"))
        await Self.settle { trail.trail.current?.location.key.tab == second }
        #expect(services.registry.perform("focusHistoryForward"))
        #expect(trail.trail.current?.location.key.tab == second)
    }

    @Test func aClosedWorkspaceIsListedUnderClosedHistory() async throws {
        let services = ActionBindingCoverageTests.boundServices()
        services.windows.ordersWindowsIn = false
        let store = services.daemon.store
        store.apply(.connected(DaemonIdentity(generation: "g1"), generationChanged: false))
        _ = services.closedWorkspaces
        store.apply(snapshot: try Self.tree(tabs: [7]))
        await Self.settle { false }
        store.apply(snapshot: try Self.tree(tabs: [], workspaces: false))
        await Self.settle { !services.closedWorkspaces.records.isEmpty }
        let record = try #require(services.closedWorkspaces.records.first)
        #expect(record.name == "proj" && record.cwd == "/tmp/t7")
        let entries = services.history.closedEntries()
        #expect(entries.contains { entry in
            if case .closed(let item) = entry.payload { return item.kind == .workspace && item.title == "proj" }
            return false
        })
    }
}
