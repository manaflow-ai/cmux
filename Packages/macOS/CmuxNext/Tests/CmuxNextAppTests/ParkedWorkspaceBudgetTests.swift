import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// Issue 26046: a window kept every workspace it showed mounted (controller, layout tree, panes,
/// strips) until critical memory pressure, so an agent visiting 400 workspaces grew the app's
/// footprint with every one. A window now keeps the `ParkedWorkspaceBudget.standard` capacity most recently
/// shown parked; the older ones leave and mount again when shown.
@MainActor struct ParkedWorkspaceBudgetTests {
    @Test func evictsTheLeastRecentlyParkedPastCapacity() {
        let parked = (1...6).map { (id: "w\($0)", serial: UInt64($0)) }.shuffled()
        #expect(ParkedWorkspaceBudget(capacity: 4).evictions(parked: parked, kept: []) == ["w1", "w2"])
        #expect(ParkedWorkspaceBudget(capacity: 6).evictions(parked: parked, kept: []).isEmpty)
    }

    @Test func neverEvictsAKeptWorkspace() {
        let parked = (1...6).map { (id: "w\($0)", serial: UInt64($0)) }
        // The one under a top page and a multi-view companion stay, so the next oldest go.
        #expect(ParkedWorkspaceBudget(capacity: 4).evictions(parked: parked, kept: ["w1", "w3"]) == ["w2", "w4"])
        // Only kept ones over capacity: nothing to evict.
        #expect(ParkedWorkspaceBudget(capacity: 1).evictions(parked: Array(parked.prefix(3)), kept: ["w1", "w2", "w3"]).isEmpty)
    }

    private static func tree(_ keys: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            let pane = PaneSnapshot(id: PaneID(rawValue: UInt64(index + 1)), tabs: [TabSnapshot(surface: SurfaceID(rawValue: UInt64(index + 1)), title: "~")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: UInt64(index + 1)), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
        })
        tree.personal = PersonalState(workspaces: keys.enumerated().map { index, key in
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index)
        })
        return tree
    }

    /// The reproduction's shape at a tenth of the size: visit 40 one-terminal workspaces in turn.
    @Test func aWindowVisitingManyWorkspacesKeepsABoundedSetMounted() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let count = ParkedWorkspaceBudget.standard.capacity + 8
        let keys = (0..<count).map { "k\($0)" }
        store.apply(snapshot: Self.tree(keys))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"parked-budget","workspace_key":"k0"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = keys
        let controller = WindowController(state: state, services: services, frame: NSRect(x: 200, y: 200, width: 1100, height: 720))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        for key in keys {
            state.showWorkspace(key)
            controller.showWorkspace(requested: state.workspaceID)
            #expect(controller.content?.workspace.id == key, "the window did not show \(key)")
        }
        #expect(controller.parked.count == ParkedWorkspaceBudget.standard.capacity, "the window kept \(controller.parked.count) workspaces parked")
        // The most recently shown stay warm; the oldest left.
        let recent = Set(keys.dropLast().suffix(ParkedWorkspaceBudget.standard.capacity))
        #expect(Set(controller.parked.keys) == recent)
        #expect(controller.parked["k0"] == nil)

        // With the set full, the oldest parked one swaps back in warm: parking the current one does not trim it.
        let oldestKey = try #require(controller.parked.min { $0.value.parkedSerial < $1.value.parkedSerial }?.key)
        let oldest = try #require(controller.parked[oldestKey])
        state.showWorkspace(oldestKey)
        controller.showWorkspace(requested: state.workspaceID)
        #expect(controller.content === oldest, "showing the oldest parked workspace evicted it")
        #expect(controller.parked.count == ParkedWorkspaceBudget.standard.capacity)
        // The one shown just before swaps back in warm.
        let previous = try #require(controller.parked[keys[count - 1]])
        state.showWorkspace(keys[count - 1])
        controller.showWorkspace(requested: state.workspaceID)
        #expect(controller.content === previous, "a recent workspace mounted again instead of swapping in warm")
        // An evicted one mounts again when shown.
        state.showWorkspace("k0")
        controller.showWorkspace(requested: state.workspaceID)
        #expect(controller.content?.workspace.id == "k0")
        #expect(controller.parked.count == ParkedWorkspaceBudget.standard.capacity)
    }
}
