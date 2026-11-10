import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAppCore
@testable import CmuxNextDaemon
import CmuxNextLayout
import CmuxNextSidebar
import Foundation
import Testing

/// The review of #40649 at 798072b0596f: the close-selection rule through the app's own paths. A create goes
/// through `WorkspaceSpawner.start`, a close through the daemon's delta (`WindowManager.reconcileMembership`, its
/// `transition` and `repairSelections`) or the press (`InstantClose.begin`), over a window of the real
/// `WindowManager` and a store that lists the workspaces.
@MainActor @Suite(.serialized)
struct WorkspaceCloseReviewTests {
    private static func workspace(_ key: String, surface: UInt64) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: surface), tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface), title: key)])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: surface), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: surface), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    /// The daemon's tree with the workspaces `keys`, in that order. A key keeps its handle in every tree.
    private static func tree(_ keys: [String]) -> DaemonTree {
        let all = ["a", "b", "c", "d", "n", "x"]
        func surface(_ key: String) -> UInt64 { UInt64((all.firstIndex(of: key) ?? all.count) + 1) }
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.map { workspace($0, surface: surface($0)) })
        tree.personal = PersonalState(workspaces: keys.enumerated().map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0)
        })
        return tree
    }

    private static func until(_ done: () -> Bool) async throws {
        for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The app with one window that lists a, b, c, d and shows b.
    private static func launch() async throws -> (services: AppServices, controller: WindowController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: tree(["a", "b", "c", "d"]))
        let controller = try #require(services.windows.openWindow(workspaces: ["a", "b", "c", "d"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        // The store tells the window manager of a change of its workspace list only through the hook that
        // `reconcileMembership` installs (the app's restore runs it; nothing else in this harness does).
        services.windows.reconcileMembership()
        try #require(store.onWorkspaceListChanged != nil, "the window manager does not hear the store's deltas")
        try await until { controller.state.workspaceID != nil }
        services.windows.show(workspaceID: "b", in: controller.state)
        try #require(controller.state.workspaceID == "b")
        return (services, controller)
    }

    /// A New Workspace `key` through `WorkspaceSpawner.start`, in the scope of the caller's run: reported to the
    /// rule (only a person's) and claimed at the press. The daemon's part is not run.
    private static func press(_ key: String, in controller: WindowController, _ services: AppServices) {
        _ = services.windows.startWorkspace(WorkspaceSpawn(newTabPage: true, key: WorkspaceKey(rawValue: key)), into: controller.state.id)
    }

    /// The store lists `keys` now: the daemon's delta, with no action run around it.
    private static func list(_ keys: [String], _ services: AppServices) {
        services.machines.local.store.apply(snapshot: tree(keys))
    }

    /// Waits until the window lists `id` and its claim is gone (the delta arrived), then, at most 2 s and with no
    /// failure, until the sidebar's model lists its row (the pick reads the rows; a later observation makes them).
    private static func listed(_ id: String, in controller: WindowController, _ services: AppServices) async throws {
        let windows = services.windows
        try await until { windows.registry.value.owner(of: id) == controller.state.id }
        try #require(windows.registry.value.owner(of: id) == controller.state.id, "the delta did not put \(id) in the window")
        try #require(windows.claims.pending[id] == nil, "the claim of \(id) stayed after the delta")
        try await until { controller.sidebar.model.allWorkspaces.contains { $0.id.rawValue == id } }
    }

    /// The person's Cmd-N from b: made, shown at the press, then listed (after b, unless `keys` says where).
    private static func personMakesN(in controller: WindowController, _ services: AppServices, listed keys: [String] = ["a", "b", "n", "c", "d"]) async throws {
        let windows = services.windows, state = controller.state
        press("n", in: controller, services)
        try #require(windows.claims.pending["n"] == state.id, "the press did not claim the new workspace")
        windows.show(workspaceID: "n", in: state)
        try #require(state.workspaceID == "n", "the window did not show the new workspace at the press")
        list(keys, services)
        try await listed("n", in: controller, services)
        try #require(state.workspaceID == "n")
        try #require(!windows.registry.closeSelection.isEmpty, "the person's New Workspace got no opener")
    }

    /// The daemon closed `id` (the store no longer lists it): waits until the window lists it no more.
    private static func gone(_ id: String, _ keys: [String], in controller: WindowController, _ services: AppServices) async throws {
        list(keys, services)
        try await until { services.windows.registry.value.owner(of: id) == nil && controller.state.workspaceID != id }
        try #require(services.windows.registry.value.owner(of: id) == nil, "the delta did not take \(id) from the window")
    }

    /// New Workspace from b, then the daemon closes it (any close: the CLI, another client, the close's own
    /// reply): the window returns to b. The old rule (the next row) gave c.
    @Test func aNewWorkspaceClosedReturnsItsWindowToTheOneItCameFrom() async throws {
        let (services, controller) = try await Self.launch()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        try await Self.personMakesN(in: controller, services)
        try await Self.gone("n", ["a", "b", "c", "d"], in: controller, services)
        #expect(controller.state.workspaceID == "b", "closing the new workspace selected \(controller.state.workspaceID ?? "nil")")
    }

    /// A workspace a script makes (the CLI's run, which may change the view) reports no create: with no relation
    /// held, closing it selects the next row (c), not the one the window showed before (b).
    @Test func aWorkspaceAScriptMakesGetsNoOpener() async throws {
        let (services, controller) = try await Self.launch()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let windows = services.windows, state = controller.state
        ActionRunScope.carrying(ActionRunScope(origin: .cli, allowsViewChange: true)) {
            Self.press("x", in: controller, services)
            windows.show(workspaceID: "x", in: state)
        }
        Self.list(["a", "b", "x", "c", "d"], services)
        try await Self.listed("x", in: controller, services)
        try #require(state.workspaceID == "x")
        #expect(windows.registry.closeSelection.isEmpty, "a script's workspace got an opener")
        try await Self.gone("x", ["a", "b", "c", "d"], in: controller, services)
        #expect(state.workspaceID == "c", "closing the script's workspace selected \(state.workspaceID ?? "nil")")
    }

    /// Review finding A. a b* c d: the person makes n from b. A script then makes x with focus; the window selects
    /// x when the daemon's delta lists it, in a turn with no action run. That selection is the delta's, not the
    /// person's gesture, so n keeps its opener: the script shows n again, n closes, and the window returns to b.
    /// Before, the delta's selection counted as a gesture, the relation went, and the close selected c.
    @Test func aSelectionTheDaemonsDeltaMakesIsNoGesture() async throws {
        let (services, controller) = try await Self.launch()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let windows = services.windows, state = controller.state, script = ActionRunScope(origin: .cli, allowsViewChange: true)
        try await Self.personMakesN(in: controller, services)
        ActionRunScope.carrying(script) { Self.press("x", in: controller, services) }
        Self.list(["a", "b", "n", "c", "d", "x"], services)
        try await Self.listed("x", in: controller, services)
        try #require(state.workspaceID == "x", "the window did not show the script's workspace when the delta listed it")
        #expect(!windows.registry.closeSelection.isEmpty, "the delta's selection ended the person's relation")
        ActionRunScope.carrying(script) { windows.show(workspaceID: "n", in: state) }
        try #require(state.workspaceID == "n")
        try await Self.gone("n", ["a", "b", "c", "d", "x"], in: controller, services)
        #expect(state.workspaceID == "b", "closing the new workspace selected \(state.workspaceID ?? "nil")")
    }

    /// Review finding F. The press of a close (`InstantClose.begin`) hides the row and selects the opener; the
    /// close is then cancelled (the question) or refused, the row is listed again and the window shows it again.
    /// It still has its opener: the relation ends when the close is committed, not at the press.
    @Test func aCancelledCloseKeepsTheOpener() async throws {
        let (services, controller) = try await Self.launch()
        defer {
            ClosingWorkspaces.shared.end("n", refused: false, in: nil)
            controller.teardown()
            controller.window?.close()
        }
        let windows = services.windows, state = controller.state
        try await Self.personMakesN(in: controller, services)
        try #require(InstantClose.begin(["n"], in: state.id, windows: windows) == ["n"])
        #expect(state.workspaceID == "b", "the press selected \(state.workspaceID ?? "nil")")
        // Cancel, as the close action's `restore`: the row is listed again and the window shows it again.
        ClosingWorkspaces.shared.end("n", refused: false, in: nil)
        windows.show(workspaceID: "n", in: state)
        try #require(state.workspaceID == "n")
        try await Self.gone("n", ["a", "b", "c", "d"], in: controller, services)
        #expect(state.workspaceID == "b", "after a cancelled close, closing the workspace selected \(state.workspaceID ?? "nil")")
    }

    /// Second review of #40649, S4. A close of several rows keeps its own rule (the next row, else the previous
    /// one), with no opener rank: a b c d n*, n made from b, Close Below on row c closes d and n (the batch of
    /// `WorkspaceSelectionClose`, `InstantClose.begin` with 2 ids). The window shows c, as before the rule; the
    /// opener rank gave b.
    @Test func aCloseOfSeveralRowsSelectsByPositionNotTheOpener() async throws {
        let (services, controller) = try await Self.launch()
        defer {
            ClosingWorkspaces.shared.end("d", refused: false, in: nil)
            ClosingWorkspaces.shared.end("n", refused: false, in: nil)
            controller.teardown()
            controller.window?.close()
        }
        let windows = services.windows, state = controller.state
        try await Self.personMakesN(in: controller, services, listed: ["a", "b", "c", "d", "n"])
        try #require(Set(InstantClose.begin(["d", "n"], in: state.id, windows: windows)) == ["d", "n"])
        #expect(state.workspaceID == "c", "Close Below selected \(state.workspaceID ?? "nil")")
    }
}
