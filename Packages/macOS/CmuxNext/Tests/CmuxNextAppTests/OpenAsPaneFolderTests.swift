import AppKit
import CmuxNextActions
import CmuxNextCompat
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// `cmux pane open-files-as --path DIR` and `cmux pane open-find-as --path DIR`:
/// the CLI (and MCP) run of Open Files / Find as Pane opens its tab on the
/// folder the script names, not the focused terminal's.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct OpenAsPaneFolderTests {
    @Test func openFilesAsPaneOpensOnTheNamedFolder() async throws {
        try await Self.run("palette.openFilesPane", page: .filesPane) { services, key in
            services.viewers.filesPanes.route(for: key)
        }
    }

    @Test func openFindAsPaneSearchesTheNamedFolder() async throws {
        try await Self.run("palette.openFindPane", page: .findPane) { services, key in
            services.fileExplorers.findPanes.route(for: key)
        }
    }

    /// One workspace with one pane holding one tab.
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(pane.id), panes: [pane])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "open-as-ws"), name: "open-as", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "open-as-ws"), index: 0)])
        return tree
    }

    private static func run(_ id: ActionID, page: InternalPageID,
                            route: (AppServices, String) -> String?) async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree())
        let controller = try #require(services.windows.openWindow(workspaces: ["open-as-ws"], frame: CGRect(x: 200, y: 200, width: 900, height: 600)))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-open-as-pane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: folder)
        }
        // The window mounts the workspace's pane in a later layout pass: wait for that signal
        // (`PaneMounts` changes when a pane controller mounts), not for time to pass.
        for await _ in ObservationStream({ services.paneMounts.generation }) where controller.workspaceContent?.panes.isEmpty == false { break }
        try #require(controller.workspaceContent?.panes.isEmpty == false, "the window never showed the workspace's pane")
        var invocation = ActionInvocation(origin: .cli)
        invocation.arguments["path"] = .string(folder.path)
        let refusal = services.registry.capturingRefusal {
            #expect(services.registry.perform(id, invocation: invocation))
        }
        #expect(refusal == nil)
        let routes = services.pages.keys(of: page).compactMap { route(services, $0) }
        #expect(routes == [folder.standardizedFileURL.path])
    }
}
