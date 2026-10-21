import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-10-20: "New" inside a group does not keep the new workspace in that group. From a
/// workspace in a group, New Workspace (Cmd-N, the sidebar's +), New Workspace Below and Duplicate
/// make the new workspace in the SAME group, right below the one it was made from, in the home
/// session's personal state and in the window's sidebar. Real daemon, the app's launch window.
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewWorkspaceInGroupTests {
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func launch() async throws -> (AppServices, URL) {
        let binary = try #require(SameTreeDaemonBinary.url)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-ingrp-\(UUID().uuidString.prefix(8))")
        let session = "cn-ingrp-\(UUID().uuidString.prefix(8).lowercased())"
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
        return (services, root)
    }

    private static func stop(_ services: AppServices, _ root: URL) async {
        if let connection = services.daemon.connection, let identity = services.daemon.identity {
            _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                              timeout: .seconds(10))
        }
        services.daemon.shutdownConnection()
        for controller in services.windows.controllers { controller.window?.close() }
        try? FileManager.default.removeItem(at: root)
    }

    @Test func newBelowAndDuplicateFromAGroupMakeTheWorkspaceRightBelowInThatGroup() async throws {
        let (services, root) = try await Self.launch()
        let store = services.daemon.store, personal = services.machines.local.store.personal
        let window = try #require(services.windows.active?.state.id)
        let bridge = try #require(services.windows.controller(for: window)?.sidebar)
        let sidebar = bridge.model
        // A fresh loose workspace to group (the launch workspace may be Home, which no group holds).
        let launched = Set(store.workspaces.map(\.id))
        let ranNew = services.registry.perform("newTab", invocation: ActionInvocation(origin: .user))
        func fresh() -> String? { store.workspaces.first { !launched.contains($0.id) }?.id }
        await Self.wait(within: .seconds(30)) {
            fresh().map { id in services.windows.states[window]?.workspaceID == id && sidebar.workspace(CmuxNextSidebar.WorkspaceID(id)) != nil } ?? false
        }
        let first = try #require(fresh(), "newTab ran: \(ranNew)")

        // Group the window's workspace, by the path Group Workspace and a drag share.
        bridge.groupFlow.newGroup(of: [SidebarWorkspaceID(first)], name: "keep-group", byUser: false)
        func header() -> CmuxNextSidebar.GroupID? {
            guard let group = personal.groups.first(where: { $0.name == "keep-group" }) else { return nil }
            let shown = sidebar.groupID(personal: group.id.rawValue)
            return sidebar.group(shown) != nil ? shown : nil
        }
        func members() -> [String] { header().flatMap { sidebar.group($0)?.workspaces.map(\.id.rawValue) } ?? [] }
        await Self.wait(within: .seconds(30)) { members() == [first] }
        try #require(members() == [first], "the group lists \(members()); groups \(personal.groups.map(\.name)); header \(String(describing: header()))")
        let group = try #require(personal.groups.first { $0.name == "keep-group" }?.id)
        /// The group the home session's personal state files workspace `id` under.
        func filed(_ id: String) -> WorkspaceGroupID? {
            guard let qualified = WindowProfiles.qualified(id, machines: services.machines) else { return nil }
            return personal.workspace(session: qualified.session, key: qualified.key)?.group
        }

        var failures: [String] = []
        /// Runs `action` on `anchor` and expects one new workspace listed right below it in the group.
        func make(_ action: ActionID, from anchor: String) async -> String? {
            let before = Set(store.workspaces.map(\.id))
            _ = services.registry.perform(action, invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: anchor), origin: .user))
            func created() -> String? { store.workspaces.first { !before.contains($0.id) }?.id }
            func placed() -> Bool {
                guard let made = created(), let at = members().firstIndex(of: anchor) else { return false }
                return members().firstIndex(of: made) == at + 1 && filed(made) == group
            }
            await Self.wait(within: .seconds(30)) { placed() }
            if !placed() { failures.append("\(action) from \(anchor): made \(created() ?? "nothing"); the group lists \(members())") }
            return created()
        }
        // Cmd-N (and the sidebar's +) from the group's workspace.
        let cmdN = await make("newTab", from: first)
        let below = await make("workspace.newBelow", from: cmdN ?? first)
        _ = await make("workspace.duplicate", from: below ?? first)

        await Self.stop(services, root)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
