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

    private static func shown(_ name: String, in bridge: SidebarBridge) -> CmuxNextSidebar.GroupID? {
        bridge.model.sections.flatMap(\.nodes).compactMap { node -> CmuxNextSidebar.GroupID? in
            if case let .group(group) = node, group.name == name { group.id } else { nil }
        }.first
    }

    /// A new group with the launch workspace, as Group Workspace makes it; the id the sidebar shows it under as soon
    /// as it shows (on the sidebar document a turn later; before the home session's personal store has it).
    private static func freshGroup(_ name: String, _ launched: Launched) async throws -> CmuxNextSidebar.GroupID {
        let bridge = try #require(launched.bridge)
        let workspace = try #require(launched.services.daemon.store.workspaces.first?.id)
        bridge.groupFlow.newGroup(of: [CmuxNextSidebar.WorkspaceID(workspace)], name: name, byUser: false)
        await Self.wait(within: .seconds(10)) { Self.shown(name, in: bridge) != nil }
        return try #require(Self.shown(name, in: bridge), "the new group does not show")
    }

    private static func perform(_ action: ActionID, on group: CmuxNextSidebar.GroupID, _ launched: Launched, _ arguments: [String: ActionValue] = [:]) {
        _ = launched.services.registry.perform(action, invocation: ActionInvocation(
            target: ActionTargetRef(kind: .workspaceGroup, id: group.rawValue), arguments: arguments, origin: .user))
    }

    /// Collapse and Rename in the create's own turn reach the daemon's group.
    @Test func collapseAndRenameRightAfterTheCreateAreSaved() async throws {
        let launched = try await Self.launch()
        let personal = launched.services.machines.local.store.personal
        let group = try await Self.freshGroup("fresh-fold", launched)
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

    /// Ungroup right after the create: the group goes from the sidebar and the home session, stays gone, the
    /// workspace stays, and no error shows.
    @Test func ungroupRightAfterTheCreateRemovesTheGroup() async throws {
        let launched = try await Self.launch()
        let services = launched.services, personal = services.machines.local.store.personal
        let bridge = try #require(launched.bridge)
        let group = try await Self.freshGroup("fresh-gone", launched)
        Self.perform("workspaceGroup.ungroup", on: group, launched)
        func gone() -> Bool { Self.shown("fresh-gone", in: bridge) == nil && !personal.groups.contains { $0.name == "fresh-gone" } }
        await Self.wait(within: .seconds(20)) { gone() && !launched.notices.shown.isEmpty } // a refusal comes in this time
        let shownAgain = Self.shown("fresh-gone", in: bridge) != nil
        let left = personal.groups.filter { $0.name == "fresh-gone" }.map(\.id.rawValue)
        let listed = !services.daemon.store.workspaces.isEmpty
        let notices = launched.notices.shown
        await launched.stop()

        #expect(!shownAgain, "the sidebar still shows the ungrouped group")
        #expect(left.isEmpty, "the home session still has the ungrouped group: \(left)")
        #expect(listed, "Ungroup lost the workspace")
        #expect(notices.isEmpty, "the Ungroup right after the create was refused: \(notices)")
    }
}
