import AppKit
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextSidebar
import Foundation
import Testing

/// https://github.com/manaflow-ai/cmux/issues/26382: every sidebar action shows in the input's turn, holds over
/// live recomputes until its owner has it, and comes back with a visible error when the save fails.
///
/// The window's sidebar on a home session with personal state and no daemon connection: each save fails
/// ("not connected") on the turn after the gesture. Before that turn a live recompute (`resync`, what a row's
/// title or activity change runs) must still show the change; after it the change is gone and the refusal HUD
/// says why. Group Delete only patched the model: the next recompute drew the group again until the daemon's
/// delete came back, and a failed save went back without a word.
@MainActor @Suite(.serialized)
struct SidebarOptimisticSaveTests {
    final class Notices {
        var shown: [String] = []
    }

    struct Window {
        let services: AppServices
        let state: WindowState
        let bridge: SidebarBridge
        let notices: Notices
    }

    /// One window listing w1 (loose), w2 and w3 (in group "Work"); `capabilities` the home session advertises.
    static func window(capabilities: [String] = []) throws -> Window {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let store = services.machines.local.store
        let advertised = capabilities.isEmpty ? "" : #","capabilities":["# + capabilities.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let json = #"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1""# + advertised + "}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        let keys = ["w1", "w2", "w3"]
        var tree = DaemonTree(registryID: "s-local", workspaces: keys.enumerated().map { index, key in
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64(index + 1)), key: WorkspaceKey(rawValue: key), name: key)
        })
        let work = WorkspaceGroupID(rawValue: "work")
        tree.personal = PersonalState(groups: [WorkspaceGroupSnapshot(id: work, name: "Work", profile: .defaultProfile)],
                                      workspaces: keys.enumerated().map { index, key in
                                          PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: key), index: index,
                                                            group: key == "w1" ? nil : work)
                                      })
        store.apply(snapshot: tree)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"optimistic","workspace_key":"optimistic-home"}"#.utf8))
        let state = WindowState(record: record)
        services.windows.registry.provisional[state.id] = keys
        let notices = Notices()
        services.registry.remoteFailureObserver = { _, notice in notices.shown.append(notice) }
        let bridge = SidebarBridge(services: services, state: state)
        bridge.resync()
        return Window(services: services, state: state, bridge: bridge, notices: notices)
    }

    static func groups(_ bridge: SidebarBridge) -> [String] {
        bridge.model.sections.flatMap(\.nodes).compactMap { node in
            if case let .group(group) = node { group.name } else { nil }
        }
    }

    static func pinned(_ bridge: SidebarBridge) -> [String] {
        bridge.model.sections.first { $0.id == .pinned }?.workspaces.map(\.id.rawValue) ?? []
    }

    /// Group Delete (and Ungroup): the group leaves in the input's turn and stays gone through a recompute; the
    /// failed delete brings it back and says so.
    @Test func groupDeleteShowsAtOnceAndRollsBackWithAnError() async throws {
        let window = try Self.window()
        let bridge = window.bridge
        try #require(Self.groups(bridge) == ["Work"], "the window does not list the group: \(bridge.model.sections)")
        let group = try #require(bridge.model.sections.flatMap(\.nodes).compactMap { node -> GroupID? in
            if case let .group(group) = node { group.id } else { nil }
        }.first)
        bridge.handle(.ungroup(group))
        #expect(Self.groups(bridge).isEmpty, "the group is still listed after Delete")
        bridge.resync() // a live recompute before the daemon answered
        #expect(Self.groups(bridge).isEmpty, "a recompute drew the deleted group again before the daemon answered")
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !window.notices.shown.isEmpty }
        #expect(Self.groups(bridge) == ["Work"], "the group did not come back after its delete failed")
        #expect(window.notices.shown.count == 1, "the failed delete showed no error: \(window.notices.shown)")
        withExtendedLifetime(window.state) {}
    }

    /// Pin Workspace: the row is in Pinned in the input's turn, through a recompute; a failed save puts it back
    /// and says so.
    @Test func workspacePinShowsAtOnceAndRollsBackWithAnError() async throws {
        let window = try Self.window(capabilities: [DaemonCapabilities.workspacePin])
        let bridge = window.bridge
        bridge.handle(.setPinned([WorkspaceID("w1")], true))
        #expect(Self.pinned(bridge) == ["w1"], "Pin did not show at once")
        bridge.resync()
        #expect(Self.pinned(bridge) == ["w1"], "a recompute took the pin back before the daemon answered")
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !window.notices.shown.isEmpty }
        #expect(Self.pinned(bridge).isEmpty, "the pin stayed after its save failed")
        #expect(window.notices.shown.count == 1, "the failed pin showed no error: \(window.notices.shown)")
        withExtendedLifetime(window.state) {}
    }

    /// Group rename on the personal path already held as a pending edit; its failed save now also says so.
    @Test func groupRenameRollsBackWithAnError() async throws {
        let window = try Self.window()
        let bridge = window.bridge
        let group = try #require(bridge.model.sections.flatMap(\.nodes).compactMap { node -> GroupID? in
            if case let .group(group) = node { group.id } else { nil }
        }.first)
        bridge.handle(.renameGroup(group, "Renamed"))
        bridge.resync()
        #expect(Self.groups(bridge) == ["Renamed"], "Rename did not hold through a recompute")
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !window.notices.shown.isEmpty }
        #expect(Self.groups(bridge) == ["Work"], "the name stayed after its save failed")
        #expect(window.notices.shown.count == 1, "the failed rename showed no error: \(window.notices.shown)")
        withExtendedLifetime(window.state) {}
    }
}

/// The sidebar document (sidebar-v2) path of #26382: the mirror placed every pending change at once, but the rows
/// drew a group's name, color and icon, and a new group, from the confirmed records only, so Rename, a color and
/// New Group showed at the daemon's echo. The document is `SidebarGroupDragRailTests.document`; its remote never
/// answers, or refuses every change.
@MainActor @Suite(.serialized)
struct SidebarDocOptimisticGroupTests {
    @MainActor final class Remote: SidebarDocRemote {
        struct Refused: Error {}
        let refuses: Bool
        init(refuses: Bool) { self.refuses = refuses }
        var isAvailable: Bool { true }
        func get() async throws -> Data { SidebarGroupDragRailTests.document }
        func move(_ items: [String], to target: SidebarDocTarget, key: String) async throws -> SidebarDocReply { try await answer() }
        func pin(_ items: [String], key: String) async throws -> SidebarDocReply { try await answer() }
        func unpin(_ items: [String], key: String) async throws -> SidebarDocReply { try await answer() }
        func adopt(_ refs: [SidebarDocWorkspaceRef], key: String) async throws -> SidebarDocReply { try await answer() }
        func apply(ops: Data, key: String) async throws -> SidebarDocReply { try await answer() }
        private func answer() async throws -> SidebarDocReply {
            if refuses { throw Refused() }
            // The reply comes after the test ends.
            try await Task.sleep(for: .seconds(600))
            throw CancellationError()
        }
    }

    static let live = ["scratch", "docs", "web", "api", "deploy"].map { SidebarDocWorkspaceRef(sessionID: "s1", workspaceID: $0) }

    static func store(refuses: Bool = false) async throws -> SidebarDocStore {
        let store = SidebarDocStore(remote: Remote(refuses: refuses))
        store.refresh()
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.isActive }
        try #require(store.isActive, "the store did not load the document")
        return store
    }

    static func send(_ intent: SidebarIntent, to store: SidebarDocStore) {
        // The document names its workspace items `w_<workspace>` (`SidebarGroupDragRailTests.document`).
        let drag = SidebarDocDrag(item: { key in if case let .workspace(id) = key { "w_\(id.rawValue)" } else { nil } }, section: { _ in SidebarGroupDragRailTests.section }, begin: { _ in [:] }, drop: { _, _ in })
        _ = store.handle(intent, model: SidebarModel(), drag: drag, pinTitle: "Pin", unpinTitle: "Unpin")
    }

    /// The groups the rows draw now, by item id.
    static func groups(_ store: SidebarDocStore) -> [String: SidebarDocProjection.Group] {
        var groups: [String: SidebarDocProjection.Group] = [:]
        for case let .group(group) in store.projection(live: live)?.machines["s1"] ?? [] { groups[group.id] = group }
        return groups
    }

    @Test func renameAndColorShowBeforeTheEcho() async throws {
        let store = try await Self.store()
        Self.send(.renameGroup(GroupID("g_g-work"), "Renamed"), to: store)
        #expect(Self.groups(store)["g_g-work"]?.name == "Renamed", "Rename waited for the daemon's echo")
        Self.send(.setGroupColor(GroupID("g_g-infra"), .palette(.purple)), to: store)
        #expect(Self.groups(store)["g_g-infra"]?.color == GroupColor.purple.rawValue, "the group color waited for the echo")
        #expect(Self.groups(store)["g_g-work"]?.name == "Renamed", "a later change dropped the pending rename")
    }

    @Test func newGroupShowsBeforeTheEcho() async throws {
        let store = try await Self.store()
        Self.send(.createGroup(GroupID("g_new"), name: "Fresh", color: .green, workspaces: [WorkspaceID("scratch")]), to: store)
        #expect(Self.groups(store)["g_new"]?.name == "Fresh", "New Group waited for the daemon's echo: \(Self.groups(store).keys.sorted())")
    }

    @Test func deleteShowsBeforeTheEcho() async throws {
        let store = try await Self.store()
        Self.send(.ungroup(GroupID("g_g-work")), to: store)
        #expect(Self.groups(store)["g_g-work"] == nil, "Delete Group waited for the daemon's echo")
    }

    @Test func aRefusedRenameComesBackWithAnError() async throws {
        let store = try await Self.store(refuses: true)
        let refusals = SidebarOptimisticSaveTests.Notices()
        store.onRefused = { refusals.shown.append($0) }
        Self.send(.renameGroup(GroupID("g_g-work"), "Renamed"), to: store)
        #expect(Self.groups(store)["g_g-work"]?.name == "Renamed", "Rename waited for the daemon")
        await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !refusals.shown.isEmpty }
        #expect(Self.groups(store)["g_g-work"]?.name == "Work", "the refused rename stayed")
        #expect(refusals.shown.count == 1, "the refused rename showed no error")
    }
}
