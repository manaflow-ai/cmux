import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSidebar
import Foundation
import Testing

/// Regression: a run of creates at `.bottom(anchor: nil)` whose
/// placement resolves before the sidebar's rows pass has caught up with the
/// store. `WindowManager.applyPendingPlacements` resolves the slot against
/// `bridge.model.sections`, the rows the observation drew a hop ago; under
/// load (ClassicUpgradeSimulationTests on #25895 and #25953) those rows can
/// miss the workspaces made since, so `bottom` lands before rows the sidebar
/// did not list yet, or at index 0 when it listed no loose row.
///
/// Each case seeds the rendered rows, then applies a newer tree to the store
/// in the same turn (no await: the rows observation's task cannot run), and
/// places the new workspace through applyPendingPlacements' shared rows pass
/// (slot, position against the current rows, personal plan). The order the plan
/// writes, applied as the daemon applies `set-personal-workspace`, must be
/// creation order. No daemon, no window, no clock.
@MainActor @Suite(.serialized)
struct PlacementStaleRowsTests {
    static func identity(mixedOrder: Bool) throws -> DaemonIdentity {
        let capabilities = mixedOrder ? #","capabilities":["personal-mixed-order-v1"]"# : ""
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1""# + capabilities + "}"
        return try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
    }

    /// A tree with `keys` as workspaces and `personal` as the home session's personal order.
    static func tree(_ keys: [String], personal: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.sorted().enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
        tree.personal = PersonalState(workspaces: personal.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    static func applying(_ plan: PersonalSidebarPlanner.DropPlan, to order: [String]) -> [String] {
        var order = order
        for step in plan.steps {
            let key = step.workspace.key.rawValue
            order.removeAll { $0 == key }
            order.insert(key, at: min(step.index, order.count))
        }
        return order
    }

    /// `drawn`: what the rows pass last listed. `store`: the store's personal order now, the
    /// new workspace where the daemon's create put it. Returns the personal order the placement writes.
    static func place(_ new: String, drawn: [String], store: [String], mixedOrder: Bool) throws -> (written: [String], listed: [String]) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let daemonStore = services.machines.local.store
        let identity = try identity(mixedOrder: mixedOrder)
        daemonStore.noteHandshake(identity)
        daemonStore.connectionState = .connected(identity)
        daemonStore.apply(snapshot: tree(drawn, personal: drawn))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"stale","workspace_key":"stale-home"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = drawn
        let bridge = SidebarBridge(services: services, state: state)
        bridge.resync()
        // The store moves on in this turn: the rows observation has not run.
        daemonStore.apply(snapshot: tree(store, personal: store))
        services.windows.registry.provisional[state.id] = store
        // Use the same synchronous rows pass as pending placements.
        let machine = try #require(services.machines.daemon(forWorkspace: new)?.machineID)
        let section = CmuxNextSidebar.SectionID.machine(CmuxNextSidebar.MachineID(machine))
        let listed = bridge.model.sections.flatMap(\.workspaces).map(\.id.rawValue)
        #expect(listed == drawn)
        let sections = WindowManager.placementSections(in: bridge)
        let position = try #require(WorkspaceSlot.bottom(anchor: nil).position(moving: [new], section: section, in: sections))
        let plan = try #require(PersonalSidebarPlanner(machines: services.machines).dropPlan([SidebarWorkspaceID(new)], at: position, in: sections))
        return (applying(plan, to: store), listed)
    }

    /// k2 already came over at the bottom; k3 was just made (the daemon put it first); the drawn rows still list only k1.
    @Test(arguments: [false, true])
    func bottomAfterRowsTheSidebarHasNotDrawnYet(mixedOrder: Bool) throws {
        let (written, listed) = try Self.place("k3", drawn: ["k1"], store: ["k3", "k1", "k2"], mixedOrder: mixedOrder)
        #expect(written == ["k1", "k2", "k3"], "bottom wrote \(written) against drawn rows \(listed)")
    }

    /// A listed moving row is not evidence that every preceding create has reached the rows pass.
    @Test(arguments: [false, true])
    func bottomWhenTheMovingRowIsAlreadyDrawn(mixedOrder: Bool) throws {
        let (written, listed) = try Self.place("k3", drawn: ["k3", "k1"], store: ["k3", "k1", "k2"], mixedOrder: mixedOrder)
        #expect(written == ["k1", "k2", "k3"], "bottom wrote \(written) against drawn rows \(listed)")
    }

    /// The drawn rows list no loose workspace yet (the first creates of a run): `bottom` resolves to index 0.
    @Test(arguments: [false, true])
    func bottomWhenTheDrawnRowsListNoLooseRow(mixedOrder: Bool) throws {
        let (written, listed) = try Self.place("k3", drawn: [], store: ["k3", "k1", "k2"], mixedOrder: mixedOrder)
        #expect(written == ["k1", "k2", "k3"], "bottom wrote \(written) against drawn rows \(listed)")
    }
    @MainActor private final class RowPassCount {
        var value = 0
    }

    /// Several daemon creates can arrive together. Pending placement keeps
    /// request order and refreshes the store-backed rows only once per window.
    @Test(arguments: [false, true])
    func aBottomBurstKeepsRegistrationOrderWithOneRowsPass(mixedOrder: Bool) throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try Self.identity(mixedOrder: mixedOrder)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(["k1"], personal: ["k1"]))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: ["k1"]))
        defer { controller.teardown(); controller.window?.close() }
        let bridge = controller.sidebar
        bridge.resync()
        let newIDs = ["k2", "k3", "k4"]
        for id in newIDs {
            NewWorkspacePlacements.expect(id, in: controller.state.id, slot: .bottom(anchor: nil), byDefault: nil, windows: windows)
        }
        let stored = ["k4", "k3", "k2", "k1"]
        store.apply(snapshot: Self.tree(stored, personal: stored))
        windows.registry.apply { $0.openWindow(id: controller.state.id, workspaceIDs: stored) }
        let count = RowPassCount()
        bridge.sameTurn.observe(listsRows: true, { count.value += 1; return count.value }, apply: { _ in })
        windows.applyPendingPlacements(live: Set(stored))
        #expect(bridge.model.selectableWorkspaces.map(\.id.rawValue) == ["k1", "k2", "k3", "k4"])
        #expect(count.value == 1, "the burst refreshed the full rows pass once per pending workspace")
        #expect(windows.pendingPlacements.isEmpty)
        #expect(windows.pendingPlacementOrder.isEmpty)
    }

}
