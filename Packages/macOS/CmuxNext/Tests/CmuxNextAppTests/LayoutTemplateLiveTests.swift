import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextWakeups
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
            work: BackgroundWork(label: "test.daemon-launcher"),
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
        // A workspace of one terminal (the launch workspace may show the New Tab page, which a
        // template does not keep).
        WorkspaceHandlers.createAndShow(services: services, name: "source")
        let named = { store.workspaces.first { $0.name == "source" && $0.screens.first?.panes.first?.tabs.isEmpty == false } }
        await Self.wait(within: .seconds(30)) { named() != nil }
        let source = try #require(named(), "the source workspace never appeared")
        let pane = try #require(source.screens.first?.panes.first)
        let connection = try #require(services.daemon.connection)
        try await connection.split(pane.handle, direction: .right)
        // Both panes and the new pane's terminal tab (a pane is mirrored before its tab).
        let split = { source.screens.first.map { $0.panes.count == 2 && $0.panes.allSatisfy { !$0.tabs.isEmpty } } == true }
        await Self.wait(within: .seconds(30), until: split)
        #expect(split(), "the split never reached the store")

        let save = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: source.id),
                                    arguments: ["name": .string("Two up")], origin: .cli)
        #expect(await LayoutTemplateTests.run(services, "saveLayoutTemplate", save) == nil)
        let saved = try #require(services.layoutTemplates.template(named: "Two up"))
        #expect(saved.blueprint.screens.flatMap(\.columns).map(\.root.paneCount).reduce(0, +) == 2, "\(saved.blueprint)")
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
