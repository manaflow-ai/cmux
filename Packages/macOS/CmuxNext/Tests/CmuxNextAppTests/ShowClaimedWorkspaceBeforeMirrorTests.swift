import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// SHORTCUT-F9 (fleet steps 151622cdd9f4, 82af71b9b05b: 3 of 9 trials on 2 display Macs): a workspace made with
/// `createWorkspace` and then shown with `show(workspaceID:in:)` before the store listed it stayed hidden for good:
/// the window fell back to its first listed workspace (Home, a New Tab page) and wrote that over the request, so the
/// terminal the daemon made never showed. A window asked to show a workspace it claimed waits for that workspace.
@MainActor @Suite(.serialized)
struct ShowClaimedWorkspaceBeforeMirrorTests {
    private static func workspace(_ key: String, surface: UInt64) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: surface), tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface), title: key)])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: surface), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: surface), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    private static func tree(_ keys: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { workspace($1, surface: UInt64($0 + 1)) })
        tree.personal = PersonalState(workspaces: keys.enumerated().map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0)
        })
        return tree
    }

    @Test func aShownWorkspaceTheStoreListsLaterIsTheOneTheWindowShows() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(["home-ws"]))
        let controller = try #require(services.windows.openWindow(workspaces: ["home-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.state.workspaceID != "home-ws" { try await Task.sleep(for: .milliseconds(10)) }
        try #require(controller.state.workspaceID == "home-ws")

        // The create claimed the new workspace at the press; its reply came before the store applied it, and the
        // caller shows it now.
        services.windows.claimNew(workspaceID: "new-ws", window: controller.state.id)
        services.windows.show(workspaceID: "new-ws", in: controller.state)
        #expect(controller.state.workspaceID == "new-ws", "the window replaced the request with \(controller.state.workspaceID ?? "nil")")

        // The store lists it: the window shows it.
        store.apply(snapshot: Self.tree(["home-ws", "new-ws"]))
        for _ in 0..<200 where controller.workspaceContent?.workspace.key?.rawValue != "new-ws" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.state.workspaceID == "new-ws")
        #expect(controller.workspaceContent?.workspace.key?.rawValue == "new-ws",
                "the window shows \(controller.workspaceContent?.workspace.key?.rawValue ?? "nothing") after the store listed the new workspace")
    }

    /// A create that fails while its window waits for it gives the window back: it shows its first workspace
    /// again (review of #32053: the claim went, and nothing showed the window again).
    @Test func aWindowWaitingForAWorkspaceWhoseCreateFailedShowsItsFirstWorkspace() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(["home-ws"]))
        let controller = try #require(services.windows.openWindow(workspaces: ["home-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        defer {
            controller.teardown()
            controller.window?.close()
        }
        for _ in 0..<200 where controller.state.workspaceID != "home-ws" { try await Task.sleep(for: .milliseconds(10)) }
        services.windows.claimNew(workspaceID: "new-ws", window: controller.state.id)
        services.windows.show(workspaceID: "new-ws", in: controller.state)
        try #require(controller.state.workspaceID == "new-ws", "the window does not wait for the claimed workspace")
        _ = services.windows.createFailed("new-ws", DaemonError.notConnected)
        #expect(controller.state.workspaceID == "home-ws", "the window still waits for a workspace whose create failed")
        #expect(controller.workspaceContent?.workspace.key?.rawValue == "home-ws")
    }
}
