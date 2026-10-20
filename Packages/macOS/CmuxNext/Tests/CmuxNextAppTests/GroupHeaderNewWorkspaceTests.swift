import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// New Workspace in Group (a group header's + and its menu) on the real daemon and the app's
/// launch window: the new workspace joins that group, in the home session's personal state and in
/// the window's sidebar. It used to be made outside the group: the group was set right after the
/// create, before the store listed the workspace, so the place went out without its public id; on
/// the sidebar document the slot's placement also named the group by its item, which no daemon knows.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct GroupHeaderNewWorkspaceTests {
    /// Polls until `done` holds or `limit` passes (a poll, as in `RapidWorkspaceCreateTests`).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The id the sidebar lists group `id` under: the document's item, else the group's own.
    private static func headerID(of id: WorkspaceGroupID, in sidebar: SidebarModel) -> CmuxNextSidebar.GroupID? {
        [CmuxNextSidebar.GroupID("itm_g_" + id.rawValue), CmuxNextSidebar.GroupID(id.rawValue)].first { sidebar.group($0) != nil }
    }

    private struct Launched {
        let services: AppServices
        let root: URL

        func stop() async {
            if let connection = services.daemon.connection, let identity = services.daemon.identity {
                _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                                  timeout: .seconds(10))
            }
            services.daemon.shutdownConnection()
            for controller in services.windows.controllers { controller.window?.close() }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func launch() async throws -> Launched {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-gplus-\(UUID().uuidString.prefix(8))")
        let session = "cn-gplus-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        await Self.wait(within: .seconds(90)) {
            services.windows.active.flatMap { services.windows.registry.members(of: $0.state.id).first } != nil
                && services.machines.local.store.personal.isLoaded
        }
        return Launched(services: services, root: root)
    }

    @Test func groupHeaderPlusMakesTheNewWorkspaceInThatGroup() async throws {
        let launched = try await Self.launch()
        let services = launched.services
        let store = services.daemon.store, personal = services.machines.local.store.personal
        let window = try #require(services.windows.active?.state.id)
        let sidebar = try #require(services.windows.controller(for: window)?.sidebar.model)

        // A group of the launch workspace, as Group Workspace makes it.
        _ = services.registry.perform("newWorkspaceGroup", invocation: ActionInvocation(arguments: ["name": .string("plus-group")]))
        await Self.wait(within: .seconds(30)) {
            personal.groups.first { $0.name == "plus-group" }.map { Self.headerID(of: $0.id, in: sidebar) != nil } ?? false
        }
        let group = try #require(personal.groups.first { $0.name == "plus-group" })
        // The id the window's sidebar lists the group under (the document's `itm_g_<id>`).
        let header = try #require(Self.headerID(of: group.id, in: sidebar))
        let before = Set(store.workspaces.map(\.id))

        // A person's New Workspace in Group, by the group's own id (the CLI's and MCP's target).
        let ran = services.registry.perform("workspaceGroup.newWorkspace", invocation: ActionInvocation(
            target: ActionTargetRef(kind: .workspaceGroup, id: group.id.rawValue), origin: .user))
        func created() -> WorkspaceModel? { store.workspaces.first { !before.contains($0.id) } }
        func personalGroup(of workspace: WorkspaceModel) -> WorkspaceGroupID? {
            guard let qualified = WindowProfiles.qualified(workspace.id, machines: services.machines) else { return nil }
            return personal.workspace(session: qualified.session, key: qualified.key)?.group
        }
        func listedInGroup(_ id: String) -> Bool {
            sidebar.group(header)?.workspaces.contains { $0.id.rawValue == id } ?? false
        }
        await Self.wait(within: .seconds(30)) {
            created().map { personalGroup(of: $0) == group.id && listedInGroup($0.id) } ?? false
        }
        let workspace = created()
        let joined = workspace.flatMap(personalGroup(of:))
        let listed = workspace.map { listedInGroup($0.id) } ?? false

        await launched.stop()

        #expect(ran)
        let made = try #require(workspace, "no workspace was made")
        #expect(joined == group.id, "\(made.name) is in personal group \(String(describing: joined)), not \(group.id)")
        #expect(listed, "the sidebar does not list \(made.name) in the group")
    }
}
