import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Layout templates on the real daemon: a workspace split in two is saved as a template, and New
/// Workspace from Template (as `cmux workspace new-from-template --arg template=…` runs it) builds
/// a new workspace named after the template with the same two panes, new terminals in each.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct LayoutTemplateLiveTests {
    /// Polls until `done` holds or `limit` passes (as in `FirstLaunchTests`).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    @Test func aSavedSplitLayoutBuildsANewWorkspaceWithTheSamePanes() async throws {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-layout-\(UUID().uuidString.prefix(8))")
        let session = "cn-layout-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        defer {
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
            try? FileManager.default.removeItem(at: root)
        }
        let store = services.daemon.store
        await Self.wait(within: .seconds(90)) { store.workspaces.first?.screens.first?.panes.first != nil }
        let source = try #require(store.workspaces.first)
        let pane = try #require(source.screens.first?.panes.first)
        let connection = try #require(services.daemon.connection)
        try await connection.split(pane.handle, direction: .right)
        await Self.wait(within: .seconds(30)) { source.screens.first?.panes.count == 2 }
        #expect(source.screens.first?.panes.count == 2)

        let save = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: source.id),
                                    arguments: ["name": .string("Two up")], origin: .cli)
        #expect(await LayoutTemplateTests.run(services, "saveLayoutTemplate", save) == nil)
        let open = ActionInvocation(arguments: ["template": .string("Two up")], origin: .cli)
        #expect(await LayoutTemplateTests.run(services, "palette.layout.open", open) == nil)

        let built = { store.workspaces.first { $0.id != source.id && $0.name == "Two up" } }
        await Self.wait(within: .seconds(30)) { built()?.screens.first?.panes.count == 2 }
        let workspace = try #require(built(), "no workspace named after the template")
        #expect(workspace.screens.first?.panes.count == 2)
        #expect(workspace.screens.first?.panes.allSatisfy { $0.tabs.count == 1 } == true, "one new terminal per pane")
        #expect(source.screens.first?.panes.count == 2, "the source keeps its panes")

        if let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
    }
}
