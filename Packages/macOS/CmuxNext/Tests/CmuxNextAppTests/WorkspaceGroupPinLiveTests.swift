import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Pin/Unpin Group on the real daemon and the app's launch window (https://github.com/manaflow-ai/cmux/issues/22259):
/// a pinned group moves into Pinned on the sidebar document, keeps its place there and reads as pinned in the
/// window's sidebar and in the home session's personal group; Unpin brings it back. Three entrypoints: the header
/// menu's Pin/Unpin Group (the id the sidebar shows), `cmux workspace group <g> update --pinned` (the daemon's
/// `workspace_group.update`), and the action with a `pinned` state (the cmux MCP tool, scripts).
@MainActor @Suite(.serialized, .timeLimit(.minutes(4)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct WorkspaceGroupPinLiveTests {
    /// Polls until `done` holds or `limit` passes (a poll, as in `GroupHeaderNewWorkspaceTests`).
    private static func wait(within limit: Duration, until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private final class Refusals {
        var reasons: [String] = []
    }

    private struct Launched {
        let services: AppServices
        let root: URL
        let refusals: Refusals

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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-gpin-\(UUID().uuidString.prefix(8))")
        let session = "cn-gpin-\(UUID().uuidString.prefix(8).lowercased())"
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: session, stateDirectory: root.appendingPathComponent("state")),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh", "TERM": "xterm-256color"] })
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.palette.bindRegistryActions()
        services.windows.ordersWindowsIn = false
        let refusals = Refusals()
        services.registry.refusalObserver = { reason, _ in refusals.reasons.append(reason) }
        services.daemon.start {
            DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil, sessionEvents: true), endpointProvider: launcher.endpointProvider)
        }
        services.windows.restoreWhenLoaded()
        await wait(within: .seconds(90)) {
            services.windows.active.flatMap { services.windows.registry.members(of: $0.state.id).first } != nil
                && services.machines.local.store.personal.isLoaded
        }
        return Launched(services: services, root: root, refusals: refusals)
    }

    /// Runs `body` on a launched app and daemon, and stops them after it, also when it throws.
    private static func withLaunched(_ body: (Launched) async throws -> Void) async throws {
        let launched = try await launch()
        do {
            try await body(launched)
        } catch {
            await launched.stop()
            throw error
        }
        await launched.stop()
    }

    /// A group of the launch workspace, as Group Workspace makes it, once the window's sidebar lists it on the
    /// sidebar document: its personal id and the id the sidebar shows it under (`itm_g_<id>`).
    /// `empty`: a group with no workspace (a saved group kept when its workspaces closed), made as the CLI makes one.
    private static func makeGroup(_ name: String, empty: Bool = false,
                                  _ launched: Launched) async throws -> (personal: WorkspaceGroupID, shown: CmuxNextSidebar.GroupID) {
        let services = launched.services, personal = services.machines.local.store.personal
        let window = try #require(services.windows.active?.state.id)
        let sidebar = try #require(services.windows.controller(for: window)?.sidebar.model)
        if empty {
            let connection = try #require(services.machines.local.connection)
            _ = try await connection.state.createWorkspaceGroup(name: name, room: nil, color: nil)
        } else {
            _ = services.registry.perform("newWorkspaceGroup", invocation: ActionInvocation(arguments: ["name": .string(name)]))
        }
        func shown() -> CmuxNextSidebar.GroupID? {
            guard let group = personal.groups.first(where: { $0.name == name }) else { return nil }
            let id = sidebar.groupID(personal: group.id.rawValue)
            guard sidebar.group(id) != nil, let store = services.sidebarDoc.store, store.isActive,
                  store.records.items[id.rawValue]?.body.isGroup == true else { return nil }
            return id
        }
        await wait(within: .seconds(30)) { shown() != nil }
        let group = try #require(personal.groups.first { $0.name == name }, "no personal group \(name)")
        let id = try #require(shown(), "the sidebar document does not list \(name): \(launched.refusals.reasons)")
        return (group.id, id)
    }

    /// Pinned in all three places a person and a script read: the document (the group item in Pinned), the
    /// window's sidebar (the header reads pinned, so its menu offers Unpin), the personal group's saved flag.
    private static func state(_ group: (personal: WorkspaceGroupID, shown: CmuxNextSidebar.GroupID), _ launched: Launched) -> [Bool?] {
        let services = launched.services
        let sidebar = services.windows.active.flatMap { services.windows.controller(for: $0.state.id)?.sidebar.model }
        return [services.sidebarDoc.store?.records.isPinned(group: group.shown.rawValue),
                sidebar?.group(group.shown)?.isPinned,
                services.machines.local.store.personal.group(group.personal)?.pinned]
    }

    private static func expectPinned(_ pinned: Bool, _ group: (personal: WorkspaceGroupID, shown: CmuxNextSidebar.GroupID),
                                     _ launched: Launched, _ step: String) async {
        await wait(within: .seconds(20)) { state(group, launched) == [pinned, pinned, pinned] }
        #expect(state(group, launched) == [pinned, pinned, pinned],
                "\(step): [document, sidebar, personal] = \(state(group, launched)), refusals \(launched.refusals.reasons)")
    }

    /// The header menu's Pin/Unpin Group runs `workspaceGroup.togglePin` on the id the sidebar shows.
    @Test func pinGroupFromTheHeaderMenuPinsAndUnpins() async throws {
        try await Self.withLaunched { launched in
            let group = try await Self.makeGroup("menu-pin", launched)
            let target = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: group.shown.rawValue), origin: .user)
            await Self.expectPinned(false, group, launched, "new group")
            #expect(launched.services.registry.perform("workspaceGroup.togglePin", invocation: target), "\(launched.refusals.reasons)")
            await Self.expectPinned(true, group, launched, "Pin Group")
            #expect(launched.services.registry.perform("workspaceGroup.togglePin", invocation: target), "\(launched.refusals.reasons)")
            await Self.expectPinned(false, group, launched, "Unpin Group")
        }
    }

    /// An empty group (Pin's own case: a saved group stays when its workspaces close) drew its header in Pinned
    /// as not pinned, so Pin Group showed again and was refused; Unpin was refused too (`no_machine`).
    @Test func anEmptyGroupPinsFromTheMenuAndUnpinsFromTheCLI() async throws {
        try await Self.withLaunched { launched in
            let group = try await Self.makeGroup("empty-pin", empty: true, launched)
            let target = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: group.shown.rawValue), origin: .user)
            #expect(launched.services.registry.perform("workspaceGroup.togglePin", invocation: target), "\(launched.refusals.reasons)")
            await Self.expectPinned(true, group, launched, "Pin Group on an empty group")
            let connection = try #require(launched.services.machines.local.connection)
            try await connection.state.updateWorkspaceGroup(group.personal.rawValue, pinned: false)
            await Self.expectPinned(false, group, launched, "update --pinned false on an empty group")
        }
    }

    /// Move to Group puts a workspace that is not pinned into a pinned group: it joins the group in Pinned, in the
    /// document and in the personal store, and the group stays pinned.
    @Test func aWorkspaceMovesIntoAPinnedGroup() async throws {
        try await Self.withLaunched { launched in
            let services = launched.services
            let group = try await Self.makeGroup("join-pinned", empty: true, launched)
            let target = ActionInvocation(target: ActionTargetRef(kind: .workspaceGroup, id: group.shown.rawValue), origin: .user)
            #expect(services.registry.perform("workspaceGroup.togglePin", invocation: target), "\(launched.refusals.reasons)")
            await Self.expectPinned(true, group, launched, "Pin Group")
            let workspace = try #require(services.daemon.store.workspaces.first, "no launch workspace")
            let item = try #require(services.sidebarDoc.item(workspace: workspace.id), "the launch workspace has no document item")
            #expect(services.sidebarDoc.store?.records.items[item]?.parent == nil, "the launch workspace starts loose")
            #expect(services.registry.perform("moveWorkspaceToGroup", invocation: ActionInvocation(
                target: ActionTargetRef(kind: .workspace, id: workspace.id),
                arguments: ["group": .target(ActionTargetRef(kind: .workspaceGroup, id: group.personal.rawValue))], origin: .user)),
                "\(launched.refusals.reasons)")
            @MainActor func joined() -> Bool {
                guard let qualified = WindowProfiles.qualified(workspace.id, machines: services.machines) else { return false }
                return services.sidebarDoc.store?.records.items[item]?.parent == group.shown.rawValue
                    && services.machines.local.store.personal.workspace(session: qualified.session, key: qualified.key)?.group == group.personal
            }
            await Self.wait(within: .seconds(20)) { joined() }
            #expect(joined(), "the workspace did not join the pinned group: \(launched.refusals.reasons)")
            await Self.expectPinned(true, group, launched, "after the move")
        }
    }

    /// `cmux workspace group <g> update --pinned true|false` writes the personal group; the document follows it.
    @Test func cliPinnedUpdateMovesTheGroup() async throws {
        try await Self.withLaunched { launched in
            let group = try await Self.makeGroup("cli-pin", launched)
            let connection = try #require(launched.services.machines.local.connection)
            try await connection.state.updateWorkspaceGroup(group.personal.rawValue, pinned: true)
            await Self.expectPinned(true, group, launched, "update --pinned true")
            try await connection.state.updateWorkspaceGroup(group.personal.rawValue, pinned: false)
            await Self.expectPinned(false, group, launched, "update --pinned false")
        }
    }

    /// The MCP tool names the group by its own id and sets a state: the same state twice is no toggle.
    @Test func pinnedArgumentSetsTheState() async throws {
        try await Self.withLaunched { launched in
            let group = try await Self.makeGroup("mcp-pin", launched)
            @MainActor func run(_ pinned: Bool) -> Bool {
                launched.services.registry.perform("workspaceGroup.togglePin", invocation: ActionInvocation(
                    target: ActionTargetRef(kind: .workspaceGroup, id: group.personal.rawValue), arguments: ["pinned": .bool(pinned)], origin: .mcp))
            }
            #expect(run(true), "\(launched.refusals.reasons)")
            await Self.expectPinned(true, group, launched, "pinned: true")
            #expect(run(true))
            await Self.expectPinned(true, group, launched, "pinned: true again")
            #expect(run(false))
            await Self.expectPinned(false, group, launched, "pinned: false")
        }
    }
}
