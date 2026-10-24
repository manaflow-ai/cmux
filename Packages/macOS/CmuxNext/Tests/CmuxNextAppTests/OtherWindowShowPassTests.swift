import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A workspace added to, moved into or closed in window B runs no `showWorkspace` pass in window A
/// (PL-script B6): every window observed the store's whole workspace list, so each change anywhere
/// re-ran every window's show pass, parked-workspace pruning included.
@MainActor @Suite(.serialized) struct OtherWindowShowPassTests {
    private static func tree(_ keys: [String]) -> DaemonTree {
        var handle: UInt64 = 0
        let workspaces = keys.map { key -> WorkspaceSnapshot in
            handle += 1
            let pane = PaneSnapshot(id: PaneID(rawValue: handle), tabs: [TabSnapshot(surface: SurfaceID(rawValue: handle), title: "~")])
            let screen = ScreenSnapshot(id: ScreenID(rawValue: handle), layout: .leaf(pane.id), panes: [pane])
            return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: handle), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
        }
        var tree = DaemonTree(registryID: "s-local", workspaces: workspaces)
        tree.personal = PersonalState(workspaces: keys.enumerated().map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $0.element), index: $0.offset)
        })
        return tree
    }

    @Test func workspacesAddedAndMovedInAnotherWindowRunNoShowPassHere() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        var keys = ["ow-a", "ow-b"]
        store.apply(snapshot: Self.tree(keys))
        let a = try #require(services.windows.openWindow(workspaces: ["ow-a"]))
        let b = try #require(services.windows.openWindow(workspaces: ["ow-b"]))
        defer { for controller in services.windows.controllers { controller.window?.close() } }
        for _ in 0..<200 where a.workspaceContent == nil || b.workspaceContent == nil { try await Task.sleep(for: .milliseconds(10)) }
        try #require(a.workspaceContent?.workspace.id == "ow-a" && b.workspaceContent?.workspace.id == "ow-b")
        await Task.yield()
        let passes = a.showPasses

        for index in 0..<100 {
            let key = "ow-b\(index)"
            keys.append(key)
            store.apply(snapshot: Self.tree(keys))
            services.windows.moveWorkspaces([key], toWindow: b.state.id, select: index % 10 == 0)
            if index % 10 == 9 { await Task.yield() }
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(services.windows.registry.members(of: b.state.id).count == 101, "the workspaces did not move into window B")
        #expect(a.showPasses == passes, "window A ran \(a.showPasses - passes) show passes for changes in window B")
        #expect(a.workspaceContent?.workspace.id == "ow-a")
    }
}
