import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Leo 2026-11-06: "when I create new groups or whatever, I can't ungroup." On the real daemon a new group is made
/// under the daemon's own id, while the sidebar shows it under the id it minted. A group menu action run right after
/// the create (Collapse, Rename, Ungroup) went to the home session under the sidebar's id, which the daemon never had:
/// it was refused, the change went back and an error showed. Each write now goes under the daemon's id, after the
/// create when it is still in flight.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct FreshGroupDaemonWritesTests {
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private final class Notices {
        var shown: [String] = []
    }

    private struct Launched {
        let services: AppServices
        let root: URL
        let notices: Notices

        var bridge: SidebarBridge? { services.windows.active?.sidebar }

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-fgw-\(UUID().uuidString.prefix(8))")
        let session = "cn-fgw-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let notices = Notices()
        services.registry.remoteFailureObserver = { _, notice in notices.shown.append(notice) }
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        await Self.wait(within: .seconds(90)) {
            services.windows.active.flatMap { services.windows.registry.members(of: $0.state.id).first } != nil
                && services.machines.local.store.personal.isLoaded
        }
        return Launched(services: services, root: root, notices: notices)
    }

    /// A new group with the launch workspace, as Group Workspace makes it; returns the id the sidebar shows it under.
    private static func freshGroup(_ name: String, _ launched: Launched) throws -> CmuxNextSidebar.GroupID {
        let bridge = try #require(launched.bridge)
        let workspace = try #require(launched.services.daemon.store.workspaces.first?.id)
        bridge.groupFlow.newGroup(of: [CmuxNextSidebar.WorkspaceID(workspace)], name: name, byUser: false)
        let shown = bridge.model.sections.flatMap(\.nodes).compactMap { node -> CmuxNextSidebar.GroupID? in
            if case let .group(group) = node, group.name == name { group.id } else { nil }
        }.first
        return try #require(shown, "the new group does not show")
    }

    private static func perform(_ action: ActionID, on group: CmuxNextSidebar.GroupID, _ launched: Launched, _ arguments: [String: ActionValue] = [:]) {
        _ = launched.services.registry.perform(action, invocation: ActionInvocation(
            target: ActionTargetRef(kind: .workspaceGroup, id: group.rawValue), arguments: arguments, origin: .user))
    }

    /// Collapse and Rename in the create's own turn reach the daemon's group.
    @Test func collapseAndRenameRightAfterTheCreateAreSaved() async throws {
        let launched = try await Self.launch()
        let personal = launched.services.machines.local.store.personal
        let group = try Self.freshGroup("fresh-fold", launched)
        Self.perform("workspaceGroup.collapse", on: group, launched)
        Self.perform("workspaceGroup.rename", on: group, launched, ["name": .string("fresh-fold-renamed")])
        await Self.wait(within: .seconds(30)) { personal.groups.contains { $0.name == "fresh-fold-renamed" && $0.collapsed } }
        let saved = personal.groups.first { $0.name.hasPrefix("fresh-fold") }
        let notices = launched.notices.shown
        await launched.stop()

        let made = try #require(saved, "no group was made")
        #expect(made.name == "fresh-fold-renamed", "the rename made right after the create was not saved")
        #expect(made.collapsed, "the fold made right after the create was not saved")
        #expect(notices.isEmpty, "a write right after the create was refused: \(notices)")
    }

    /// Ungroup in the create's own turn: the daemon's group goes, the workspace stays, and no error shows.
    @Test func ungroupRightAfterTheCreateRemovesTheDaemonsGroup() async throws {
        let launched = try await Self.launch()
        let services = launched.services, personal = services.machines.local.store.personal
        let bridge = try #require(launched.bridge)
        let group = try Self.freshGroup("fresh-gone", launched)
        let local = WorkspaceGroupID(rawValue: SidebarDocStore.personalGroupID(item: group.rawValue))
        Self.perform("workspaceGroup.ungroup", on: group, launched)
        // The create landed, and its group is gone again.
        await Self.wait(within: .seconds(30)) {
            bridge.groupEditor.created[local] != nil && !personal.groups.contains { $0.name == "fresh-gone" }
        }
        let landed = bridge.groupEditor.created[local] != nil
        let left = personal.groups.filter { $0.name == "fresh-gone" }.map(\.id.rawValue)
        let listed = !services.daemon.store.workspaces.isEmpty
        let notices = launched.notices.shown
        await launched.stop()

        #expect(landed, "the create never landed")
        #expect(left.isEmpty, "the daemon still has the ungrouped group: \(left)")
        #expect(listed, "Ungroup lost the workspace")
        #expect(notices.isEmpty, "the Ungroup right after the create was refused: \(notices)")
    }
}
