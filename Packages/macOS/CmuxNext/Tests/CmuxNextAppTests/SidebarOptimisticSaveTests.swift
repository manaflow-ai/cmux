import AppKit
import CmuxNextActions
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

    /// Pin Workspace on a daemon without `workspace-pin-v1`: the row goes back at once, and says why (it was silent).
    @Test func pinOnADaemonThatCannotPinSaysWhy() throws {
        let window = try Self.window()
        let bridge = window.bridge
        bridge.handle(.setPinned([WorkspaceID("w1")], true))
        #expect(Self.pinned(bridge).isEmpty, "the pin stayed on a daemon that cannot pin")
        #expect(window.notices.shown.count == 1, "the refused pin showed no error: \(window.notices.shown)")
        withExtendedLifetime(window.state) {}
    }

    /// Pin Group on a home daemon without `workspace-group-pin-v1`: no change, and the person sees why.
    @Test func groupPinOnADaemonThatCannotPinSaysWhy() throws {
        let window = try Self.window()
        let bridge = window.bridge
        let group = try #require(bridge.model.sections.flatMap(\.nodes).compactMap { node -> GroupID? in
            if case let .group(group) = node { group.id } else { nil }
        }.first)
        bridge.handle(.setGroupPinned(group, true))
        #expect(window.notices.shown.count == 1, "the refused group pin showed no error: \(window.notices.shown)")
        withExtendedLifetime(window.state) {}
    }

    /// Rename Workspace with a name (the palette prompt, the CLI, MCP): the name shows in the input's turn, and a
    /// failed save takes it back and says why. It waited for the daemon's echo, and a failure was only logged.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func renameWithANameShowsAtOnceAndRollsBackWithAnError() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        do {
            try #require(services.daemon.connection != nil)
            // A connected service applies the intent now. This key exists only in its mirror, so the real
            // daemon refuses the remote rename and exercises rollback instead of the disconnected early exit.
            let id = try LayoutTemplateTests.workspace(services, key: "ws-rename", name: "api")
            let store = services.machines.local.store
            let rename = ActionInvocation(target: ActionTargetRef(kind: .workspace, id: id), arguments: ["name": .string("Renamed")], origin: .cli)
            let work = services.registry.capturingWork { _ = services.registry.perform("renameWorkspace", invocation: rename) }
            #expect(store.workspaces.first?.name == "Renamed", "the new name waited for the daemon's echo")
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            // The refusal can also bring the daemon's own tree, which lacks the mirror-only key: look the workspace up
            // by key, and the new name must be gone either way.
            let renamed = store.workspaces.first { $0.key?.rawValue == "ws-rename" }
            #expect(renamed.map { $0.name == "api" } ?? true, "the name stayed after its save failed")
            #expect(!store.workspaces.contains { $0.name == "Renamed" }, "the name stayed after its save failed")
            #expect(failures.count == 1, "the failed rename reported no error: \(failures)")
        } catch {
            await launched.stop()
            throw error
        }
        await launched.stop()
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

    /// A move into a group created a moment ago (its create still in flight) is the document's: it read the
    /// confirmed records, which do not have the group yet, and fell back to the older path.
    @Test(arguments: ["confirmed", "adopted", "pending-pin"])
    func aMoveIntoANewGroupIsTakenBeforeItsEcho(placement: String) async throws {
        let store = try await Self.store()
        let refusals = SidebarOptimisticSaveTests.Notices()
        store.onRefused = { refusals.shown.append($0) }
        let first = WorkspaceID(placement == "confirmed" ? "scratch" : "unplaced")
        let drag = SidebarDocDrag(item: { key in
            if case let .workspace(id) = key, id.rawValue != "unplaced" { "w_\(id.rawValue)" } else { nil }
        }, section: { id in id == .pinned ? SidebarDocStore.pinnedSection : SidebarGroupDragRailTests.section },
           begin: { _ in [:] }, drop: { _, _ in }, adoptRef: { id in
            ["session_id": "s1", "workspace_id": id.rawValue, "workspace_key": id.rawValue]
        })
        if placement == "pending-pin" {
            try #require(store.handle(.setPinned([first], true), model: SidebarModel(), drag: drag, pinTitle: "Pin", unpinTitle: "Unpin"))
            try #require(refusals.shown.isEmpty, "the setup pin must apply before testing a drop into its group")
        }
        let created = store.handle(.createGroup(GroupID("g_new"), name: "Fresh", color: .green, workspaces: [first]), model: SidebarModel(),
                                   drag: drag, pinTitle: "Pin", unpinTitle: "Unpin")
        try #require(created)
        let request = SidebarViewRequest(live: Self.live + [SidebarDocWorkspaceRef(sessionID: "s1", workspaceID: "unplaced")])
        let group = try #require(store.rows(request)?.first(where: { $0.item == "g_new" }))
        if placement == "pending-pin" {
            try #require(group.section == SidebarDocStore.pinnedSection, "the group must follow its pending-pinned first member")
        }
        // A drop names a group the list already shows. Use the reducer's actual placement, including a pending pin.
        let nodes: [SidebarNode] = [.group(SidebarGroup(id: GroupID("g_new"), name: "Fresh", workspaces: []))]
        let section = group.section == SidebarDocStore.pinnedSection
            ? SidebarSection(kind: .custom(SidebarCustomSection(id: group.section)), nodes: nodes)
            : SidebarSection(kind: .machine(SidebarMachine(id: .local, name: "This Mac", kind: .local)), nodes: nodes)
        let model = SidebarModel(sections: [section])
        let handled = store.handle(.move([WorkspaceID("docs")], toGroup: GroupID("g_new")), model: model, drag: drag, pinTitle: "Pin", unpinTitle: "Unpin")
        #expect(handled, "the document did not take a move into the new group before its echo")
        let rows = try #require(store.rows(request))
        #expect(rows.first(where: { $0.item == "w_docs" })?.parent == "g_new", "the accepted move must show before the echo")
        #expect(refusals.shown.isEmpty, "the newly created group must have a valid drop target")
    }

    /// A collapse the document refuses at once (it is not active yet) says why, as a later refusal does.
    @Test func aCollapseRefusedAtOnceSaysWhy() {
        let store = SidebarDocStore(remote: Remote(refuses: false)) // never loaded: not active
        let refusals = SidebarOptimisticSaveTests.Notices()
        store.onRefused = { refusals.shown.append($0) }
        var folded = true
        store.setGroupCollapsed("g_g-work", true) { folded = false }
        #expect(!folded, "the refused fold kept its look")
        #expect(refusals.shown.count == 1, "the refused collapse showed no error")
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
