import AppKit
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import Foundation
import Testing

/// #32989: a Chief prompted from one window created its workspaces (`cmux workspace create`,
/// `cmux agents workspace create`) in another: the daemon has no windows, and the app gave every
/// create it did not make itself to the most recent window. The CLI now announces the create
/// (`workspace.expect_window`, keyed by its idempotency key) and the app files the workspace into
/// that window as the daemon reports it, without changing what that window shows.
@MainActor @Suite(.serialized)
struct CreateInCallerWindowTests {
    private static func workspace(_ key: String, surface: UInt64) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: surface), tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface), title: key)])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: surface), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: surface), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    private static func tree(_ keys: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaceRevision: 10, workspaces: keys.enumerated().map { workspace($1, surface: UInt64($0 + 1)) })
        tree.personal = PersonalState(workspaces: keys.enumerated().map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0)
        })
        return tree
    }

    /// Two windows; returns the one the most recent rule would NOT pick, and the other.
    private static func twoWindows(_ services: AppServices) async throws -> (prompted: WindowController, other: WindowController) {
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(["ws-a", "ws-b"]))
        let a = try #require(services.windows.openWindow(workspaces: ["ws-a"], frame: CGRect(x: 100, y: 100, width: 900, height: 600)))
        let b = try #require(services.windows.openWindow(workspaces: ["ws-b"], frame: CGRect(x: 300, y: 300, width: 900, height: 600)))
        for _ in 0..<200 where a.state.workspaceID != "ws-a" || b.state.workspaceID != "ws-b" { try await Task.sleep(for: .milliseconds(10)) }
        let recent = try #require(services.windows.registry.value.mostRecentOpen())
        return recent == a.state.id ? (b, a) : (a, b)
    }

    private static func added(_ key: String, surface: UInt64, mutation: String) -> DaemonEvent {
        .workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: surface), index: 2, entity: workspace(key, surface: surface),
                                       workspaceRevision: 11, origin: DaemonStore.resourceAPIOrigin, mutationID: mutation))
    }

    @Test func anAnnouncedCreateOpensInItsWindowNotTheMostRecent() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        let reply = try WorkspaceWindowControl.expect(["idempotency_key": "cli-key-1", "window": .string(prompted.state.id)],
                                                      topology: ControlSnapshotPublisher.topology(services), windows: services.windows)
        #expect(reply["window"] == .string(ControlWindowInfo.publicID(forKey: prompted.state.id)))
        services.machines.local.store.apply(Self.added("ws-new", surface: 3, mutation: "cli-key-1"))

        #expect(services.windows.registry.value.owner(of: "ws-new") == prompted.state.id,
                "it went to \(services.windows.registry.value.owner(of: "ws-new") ?? "no window"), not the window it was announced for")
        #expect(prompted.state.workspaceID == "ws-a", "an agent's create changed what the window shows")
    }

    @Test func aChiefTurnsCreateOpensInThePromptedWindow() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        // The person sent the Chief a message from the window the most recent rule would not pick.
        services.windows.chiefPrompt.note(prompted.window, in: services.windows)
        let topology = ControlSnapshotPublisher.topology(services)
        #expect(topology.chiefPromptWindowID == prompted.state.id)
        _ = try WorkspaceWindowControl.expect(["idempotency_key": "turn-key", "caller": ["home_chat": true]],
                                              topology: topology, windows: services.windows)
        services.machines.local.store.apply(Self.added("ws-turn", surface: 3, mutation: "turn-key"))

        #expect(services.windows.registry.value.owner(of: "ws-turn") == prompted.state.id)
    }

    @Test func anUnannouncedCreateStillGoesToTheMostRecentWindow() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        services.machines.local.store.apply(Self.added("ws-plain", surface: 3, mutation: "someone-else"))
        #expect(services.windows.registry.value.owner(of: "ws-plain") == other.state.id)
    }

    @Test func aNamedWindowTheAppDoesNotHaveIsRefused() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        #expect(throws: ControlError.self) {
            try WorkspaceWindowControl.expect(["idempotency_key": "k", "window": "win_00000000000000000000000000000000"],
                                              topology: ControlSnapshotPublisher.topology(services), windows: services.windows)
        }
    }
}
