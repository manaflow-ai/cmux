import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The app on a fresh same-tree daemon with its launch workspace in a group of its own, as the
/// sidebar shows it (the launch `GroupHeaderNewWorkspaceTests` uses: the palette's registry
/// actions bound and the personal state loaded before the group is made).
@MainActor
struct GroupedAppLaunch {
    let services: AppServices
    let workspace: WorkspaceModel
    let group: WorkspaceGroupID
    private let root: URL

    static func start() async throws -> GroupedAppLaunch {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-grouped-\(UUID().uuidString.prefix(8))")
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-grouped-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        try await PinnedPageTests.until({
            services.windows.active.flatMap { services.windows.registry.members(of: $0.state.id).first } != nil
                && services.machines.local.store.personal.isLoaded
        }, within: .seconds(90))
        let window = try #require(services.windows.active)
        let workspace = try #require(services.windows.registry.members(of: window.state.id).compactMap(services.workspace(id:))
            .first { !HomeRules.isHome($0) })
        // Group Workspace from the palette: the launch workspace, in a new group.
        _ = services.registry.perform("newWorkspaceGroup", invocation: ActionInvocation(arguments: ["name": .string("solo-group")]))
        let personal = services.machines.local.store.personal
        let sidebar = window.sidebar.model
        try await PinnedPageTests.until({
            personal.groups.first { $0.name == "solo-group" }.map { sidebar.group(sidebar.groupID(personal: $0.id.rawValue)) != nil } ?? false
        }, within: .seconds(30), report: { "groups \(personal.groups.map(\.name))" })
        let group = try #require(personal.groups.first { $0.name == "solo-group" }?.id)
        return GroupedAppLaunch(services: services, workspace: workspace, group: group, root: root)
    }

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
