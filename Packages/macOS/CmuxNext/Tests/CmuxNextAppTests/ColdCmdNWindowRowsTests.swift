import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Cold Cmd-N's wait for the current row (`NewWorkspaceDefaultSlot.awaitsCurrentAnchor`) is a property of the
/// window: its rows are built a hop after the document's `show`, so the document being caught up says nothing
/// about them (Sol on #27014). And a current row the window will never list (another window owns it) is no row to
/// wait for: the placement resolves by the documented fallback and its `then` runs.
@MainActor @Suite(.serialized) struct ColdCmdNWindowRowsTests {
    private final class Remote: SidebarDocRemote {
        var isAvailable: Bool { true }
        func get() async throws -> Data { Data(#"{"revision":"1","sections":[],"items":[]}"#.utf8) }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { reply }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { reply }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { reply }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { reply }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { reply }
        private var reply: SidebarDocReply { SidebarDocReply(revision: 2, inverse: Data("[]".utf8)) }
    }

    @MainActor private final class Ran {
        var value = false
    }

    /// An active document store, made `services`' document for `body` when given; `show` false leaves it a
    /// projection behind (cold).
    static func withDocument(shown: Bool, services: AppServices? = nil, _ body: (SidebarDocStore) async throws -> Void) async throws {
        let store = SidebarDocStore(remote: Remote())
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive)
        if shown {
            store.show(live: [])
            try #require(store.shown != nil && store.shownVersion == store.version)
        }
        services?.sidebarDoc.store = store
        try await body(store)
    }

    static func probe(window: String, current: String, machine: String) -> PendingWorkspaceRows.Row {
        let id = CmuxNextSidebar.MachineID(machine)
        return PendingWorkspaceRows.Row(
            id: "probe", window: window, machine: id,
            face: SidebarMapping.shared.creatingRow(id: "probe", machine: id, name: "probe", opensPage: true),
            slot: nil, byDefault: NewWorkspaceDefaultSlot(placement: .afterCurrent, current: current, currentMachine: machine))
    }

    /// The document caught up (`shownVersion == version`), but this window's rows were not built from its
    /// projection: they omit the current row. The stand-in waits, rather than drawing at the top or bottom.
    @Test func aWindowWhoseRowsLagTheDocumentKeepsTheStandInWaiting() async throws {
        _ = NSApplication.shared
        try await Self.withDocument(shown: true) { store in
            let model = SidebarModel()
            let rows = SidebarRows(model: model, document: { store })
            let stale = [SidebarRowSection(kind: .machine(SidebarMachine(id: CmuxNextSidebar.MachineID("m"), name: "This Mac", kind: .local)), nodes: [])]
            rows.show(stale, creating: ([Self.probe(window: "w", current: "current", machine: "m")], nil))
            let drawn = model.sections.flatMap(\.workspaces).map(\.id.rawValue)
            #expect(drawn.isEmpty, "rows a projection behind drew the cold stand-in at \(drawn)")
        }
    }

    /// Rows built from the document's current projection that still omit the current row left it out on purpose:
    /// the stand-in draws at the fallback slot.
    @Test func rowsBuiltFromTheCurrentProjectionDrawTheStandInAtTheFallback() async throws {
        _ = NSApplication.shared
        try await Self.withDocument(shown: true) { store in
            let model = SidebarModel()
            let rows = SidebarRows(model: model, document: { store })
            let stale = [SidebarRowSection(kind: .machine(SidebarMachine(id: CmuxNextSidebar.MachineID("m"), name: "This Mac", kind: .local)), nodes: [])]
            let probe = Self.probe(window: "w", current: "current", machine: "m")
            rows.show(stale, creating: ([probe], nil))
            #expect(model.sections.flatMap(\.workspaces).isEmpty)
            rows.show(stale, shownAt: store.shownChanges, creating: ([probe], nil), unlessShown: true)
            #expect(!rows.layoutCatchingUp)
            #expect(model.sections.flatMap(\.workspaces).map(\.id.rawValue) == ["probe"])
        }
    }

    /// The window's current workspace moved to another window: this one will never list it, so the cold wait
    /// resolves at once by the fallback and runs `then`.
    @Test func aCurrentWorkspaceAnotherWindowOwnsDoesNotHoldThePlacement() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["k1", "k2"], personal: ["k1", "k2"]))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: ["k2"]))
        defer { controller.teardown(); controller.window?.close() }
        windows.registry.apply { $0.openWindow(id: "other", workspaceIDs: ["k1"]) }
        controller.sidebar.resync()
        let machine = try #require(services.machines.daemon(forWorkspace: "k1")?.machineID)
        try await Self.withDocument(shown: false, services: services) { store in
            #expect(NewWorkspaceDefaultSlot.layoutCatchingUp(store))
            let ran = Ran()
            NewWorkspacePlacements.expect("k2", in: controller.state.id, byDefault: NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "k1", currentMachine: machine),
                                          then: { _, _ in ran.value = true }, windows: windows)
            #expect(windows.pendingPlacements["k2"] == nil, "the placement waits for a row another window lists")
            #expect(ran.value)
        }
    }

    /// A placement waiting for the current row whose new workspace closes (or whose create is undone) meanwhile:
    /// its entry goes with it, rather than waiting forever for a workspace the daemon no longer has.
    @Test func aWaitingPlacementWhoseWorkspaceClosesIsDropped() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["k1", "k2"], personal: ["k1", "k2"]))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: ["k2"]))
        defer { controller.teardown(); controller.window?.close() }
        controller.sidebar.resync()
        let machine = try #require(services.machines.daemon(forWorkspace: "k1")?.machineID)
        try await Self.withDocument(shown: false) { _ in
            let ran = Ran()
            NewWorkspacePlacements.expect("k2", in: controller.state.id, byDefault: NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "k1", currentMachine: machine),
                                          then: { _, _ in ran.value = true }, windows: windows)
            try #require(windows.pendingPlacements["k2"] != nil, "the placement did not wait")
            store.apply(snapshot: PlacementStaleRowsTests.tree(["k1"], personal: ["k1"]))
            windows.retryDeferredPlacements()
            #expect(windows.pendingPlacements["k2"] == nil, "a placement for closed workspace k2 is kept")
            #expect(!windows.pendingPlacementOrder.contains("k2"))
            #expect(!ran.value, "then ran for a workspace that is gone")
        }
    }

    /// A current row the window could list (no window owns it yet) that never comes: the wait ends at its limit,
    /// with no rows pass to retry it, and the placement resolves by the fallback.
    @Test func aCurrentRowThatNeverComesStopsWaitingAtTheLimit() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let identity = try PlacementStaleRowsTests.identity(mixedOrder: false)
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: PlacementStaleRowsTests.tree(["k1", "k2"], personal: ["k1", "k2"]))
        let windows = services.windows
        windows.ordersWindowsIn = false
        let controller = try #require(windows.openWindow(workspaces: ["k2"]))
        defer { controller.teardown(); controller.window?.close() }
        controller.sidebar.resync()
        let machine = try #require(services.machines.daemon(forWorkspace: "k1")?.machineID)
        try await Self.withDocument(shown: false) { _ in
            let ran = Ran()
            NewWorkspacePlacements.expect("k2", in: controller.state.id, byDefault: NewWorkspaceDefaultSlot(placement: .afterCurrent, current: "k1", currentMachine: machine),
                                          then: { _, _ in ran.value = true }, windows: windows)
            #expect(windows.pendingPlacements["k2"] != nil, "a row the window may still list is waited for")
            #expect(!ran.value)
            await RapidWorkspaceCreateTests.wait(within: NewWorkspacePlacements.anchorWaitLimit + .seconds(10)) { ran.value }
            #expect(ran.value, "the placement waited past its limit")
            #expect(windows.pendingPlacements.isEmpty)
        }
    }
}
