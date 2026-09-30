import CmuxNextDaemon
@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

/// Session-qualified ids (plans/cmux-next/data-model.md 1.3): the CLI and
/// control socket name objects of a remote session as
/// `build-box:workspace:3`; the home session keeps `workspace:3`. `session`
/// (the CLI's `--session`/`--machine`) scopes unqualified refs, indexes and
/// lists.
@Suite(.timeLimit(.minutes(1))) struct CompatSessionTests {
    static let homeID = "0f0f0f0f-0000-4000-8000-000000000001"
    static let remoteID = "b0b0b0b0-1111-4111-8111-000000000002"
    static let remoteKey = "33333333-3333-4333-8333-333333333333"

    /// The home session's sample tree plus one remote workspace whose pane
    /// and surface handles collide with home handles (handles are per daemon).
    static func topology() -> ControlTopology {
        var app = ControlTopology()
        app.sessions = [
            ControlSessionInfo(id: homeID, qualifier: "mac", machineID: "local", machineName: "Mac", isHome: true),
            ControlSessionInfo(id: remoteID, qualifier: "build-box", machineID: "ssh-1", machineName: "build-box",
                               sessionName: "main", transport: "ssh"),
        ]
        var topology = CompatFreshTopology.make(tree: sampleTree(), appState: app)
        let tab = ControlTabInfo(id: "tab_000000000000000000000000000000b1", surface: "11", kind: "terminal", title: "remote zsh",
                                 name: nil, terminalID: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", columns: nil, rows: nil, cwd: "/srv",
                                 url: nil, gitBranch: nil, isPinned: false, isDead: false, hasUnread: false)
        let pane = ControlPaneInfo(id: "pane_000000000000000000000000000000b2", handle: "2", tabs: [tab])
        topology.workspaces.append(ControlWorkspaceInfo(
            id: remoteKey, handle: "1", name: "remote", screens: [ControlScreenInfo(id: "screen-r", handle: "1", panes: [pane])],
            sessionID: remoteID))
        return topology
    }

    static func world(scope: String? = nil, refs: CompatRefRegistry = CompatRefRegistry()) throws -> CompatWorld {
        var world = CompatWorld(topology: topology(), refs: refs)
        if let scope { world.scope = try world.resolveSession(scope) }
        return world
    }

    @Test func qualifiersAreUniqueTokens() {
        let names = ControlSessionNaming.qualifiers([
            .init(id: "aaaaaaaa-0000-4000-8000-000000000000", name: "Build Box.local"),
            .init(id: "bbbbbbbb-0000-4000-8000-000000000000", name: "devvm"),
            .init(id: "cccccccc-0000-4000-8000-000000000000", name: "devvm"),
            .init(id: "dddddddd-0000-4000-8000-000000000000", name: "workspace"),
            .init(id: "machine:cloud-7", name: nil),
        ])
        #expect(names["aaaaaaaa-0000-4000-8000-000000000000"] == "build-box.local")
        // Two sessions on hosts with the same name: a registry_id prefix tells them apart.
        #expect(names["bbbbbbbb-0000-4000-8000-000000000000"] == "devvm-bbbbbbbb")
        #expect(names["cccccccc-0000-4000-8000-000000000000"] == "devvm-cccccccc")
        // A name that is a ref kind never becomes a bare qualifier.
        #expect(names["dddddddd-0000-4000-8000-000000000000"] == "workspace-dddddddd")
        #expect(names["machine:cloud-7"]?.count == 8)
        #expect(names.values.allSatisfy { !$0.contains(":") && !$0.contains(" ") })
    }

    @Test func remoteRefsAreQualifiedAndHomeRefsAreNot() throws {
        let world = try Self.world()
        let home = try #require(world.workspaces.first { $0.sessionID == nil })
        let remote = try #require(world.workspaces.first { $0.sessionID == Self.remoteID })
        #expect(home.ref == "workspace:1")
        #expect(remote.ref == "build-box:workspace:1")
        #expect(remote.index == 0 && home.index == 0)
        let remoteSurface = try #require(world.surfaces.values.first { $0.sessionID == Self.remoteID })
        #expect(remoteSurface.ref.hasPrefix("build-box:surface:"))
        // Home first: the single-session indexes and refs do not change.
        #expect(world.workspaces.map(\.title) == ["alpha", "Beta!", "remote"])
    }

    @Test func qualifiedAndScopedRefsResolveToTheirSession() throws {
        let refs = CompatRefRegistry()
        let world = try Self.world(refs: refs)
        #expect(try world.resolveWorkspace("build-box:workspace:1", refs: refs).modelID == Self.remoteKey)
        #expect(try world.resolveWorkspace("workspace:1", refs: refs).sessionID == nil)
        // The session may be named by id, id prefix, machine id or machine name.
        #expect(try world.resolveWorkspace("\(Self.remoteID):workspace:1", refs: refs).modelID == Self.remoteKey)
        #expect(try world.resolveWorkspace("b0b0b0b0:workspace:1", refs: refs).modelID == Self.remoteKey)
        #expect(try world.resolveWorkspace("ssh-1:workspace:1", refs: refs).modelID == Self.remoteKey)
        // `--session build-box`: unqualified refs and indexes address that session.
        let scoped = try Self.world(scope: "build-box", refs: refs)
        #expect(try scoped.resolveWorkspace("workspace:1", refs: refs).modelID == Self.remoteKey)
        #expect(try scoped.resolveWorkspace("0", refs: refs).modelID == Self.remoteKey)
        let surface = try scoped.resolveSurface("build-box:surface:1", in: nil, refs: refs)
        #expect(surface.sessionID == Self.remoteID && surface.title == "remote zsh")
        // A qualified raw id works too, and a UUID needs no qualifier.
        #expect(try world.resolveSurface("build-box:tab_000000000000000000000000000000b1", in: nil, refs: refs).title == "remote zsh")
        #expect(try world.resolveWorkspace(Self.remoteKey, refs: refs).sessionID == Self.remoteID)
        #expect(throws: ControlError.self) { try world.resolveWorkspace("nowhere:workspace:1", refs: refs) }
        #expect(throws: ControlError.self) { try world.resolveSession("nowhere") }
    }

    @Test func scopeFiltersListsAndPicksTheSessionsCurrentWorkspace() throws {
        let all = try Self.world()
        #expect(all.workspaces(in: nil).count == 3)
        let remote = try Self.world(scope: "build-box")
        #expect(remote.workspaces(in: nil).map(\.title) == ["remote"])
        #expect(remote.currentWorkspace(window: nil)?.modelID == Self.remoteKey)
        let home = try Self.world(scope: "home")
        #expect(home.workspaces(in: nil).map(\.title) == ["alpha", "Beta!"])
    }

    @Test func handlesAreLookedUpPerSession() throws {
        let world = try Self.world()
        // Surface handle 11 exists on both sessions.
        #expect(world.surface(CompatSurfaceHandle(handle: 11, session: nil))?.title == "zsh")
        #expect(world.surface(CompatSurfaceHandle(handle: 11, session: Self.remoteID))?.title == "remote zsh")
    }

    @Test func jsonNamesTheSession() throws {
        let world = try Self.world()
        let remote = try #require(world.workspaces.first { $0.sessionID == Self.remoteID })
        let item = CompatJSON.workspace(remote, selected: false, in: world)
        #expect(item["session_id"] == .string(Self.remoteID))
        #expect(item["session"] == "build-box")
        #expect(item["machine"] == "build-box")
        let home = try #require(world.workspaces.first)
        let homeItem = CompatJSON.workspace(home, selected: false, in: world)
        #expect(homeItem["session_id"] == .string(Self.homeID))
        #expect(homeItem["session"] == .null)
        let surface = try #require(world.surfaces.values.first { $0.sessionID == Self.remoteID })
        let ids = CompatJSON.ids(workspace: remote, surface: surface)
        #expect(ids["session"] == "build-box" && ids["surface_ref"] == .string(surface.ref))
    }

    @Test func qualifierSplittingKeepsUnqualifiedForms() {
        let known: (String) -> Bool = { $0 == "build-box" }
        #expect(CompatRefRegistry.splitQualifier("build-box:workspace:3", isSession: known) == ("build-box", "workspace:3"))
        #expect(CompatRefRegistry.splitQualifier("workspace:3", isSession: known).session == nil)
        #expect(CompatRefRegistry.splitQualifier("handle:7", isSession: { _ in true }).session == nil)
        #expect(CompatRefRegistry.splitQualifier("other:workspace:3", isSession: known).session == nil)
        #expect(CompatRefRegistry.splitQualifier(Self.remoteKey, isSession: known).session == nil)
    }

    /// A write to a remote session raises that session's barrier; a read
    /// waits until the topology reflects it.
    @Test func barrierCoversRemoteSessions() {
        var snapshot = ControlSnapshot()
        snapshot.topology = Self.topology()
        snapshot.topology.isLoaded = true
        snapshot.topology.sessionSequences = [Self.remoteID: 4]
        #expect(snapshot.reflects(ControlSequenceBarrier(home: 0, sessions: [Self.remoteID: 4])))
        #expect(!snapshot.reflects(ControlSequenceBarrier(home: 0, sessions: [Self.remoteID: 5])))
        // A session the topology no longer reports cannot hold a read forever.
        #expect(snapshot.reflects(ControlSequenceBarrier(home: 0, sessions: ["gone": 9])))
        let barrier = CompatWriteBarrier()
        barrier.raise(to: 7, session: Self.remoteID)
        barrier.raise(to: 3, session: Self.remoteID)
        barrier.raise(to: 2)
        #expect(barrier.barrier == ControlSequenceBarrier(home: 2, sessions: [Self.remoteID: 7]))
    }

    /// `action.run` targets take qualified refs (`cmux tab reload --target
    /// build-box:surface:1`).
    @Test func actionTargetsTakeQualifiedRefs() throws {
        let refs = CompatRefRegistry()
        let world = try Self.world(refs: refs)
        let form = try #require(CompatTargetForm(ControlTargetRef(kind: "tab", id: "build-box:surface:1")))
        let resolved = try form.resolve(in: world, refs: refs)
        #expect(resolved == ControlTargetRef(kind: "tab", id: "tab_000000000000000000000000000000b1"))
        let tabAlias = try #require(CompatTargetForm(ControlTargetRef(kind: "workspace", id: "build-box:tab:1")))
        #expect(try tabAlias.resolve(in: world, refs: refs) == ControlTargetRef(kind: "workspace", id: Self.remoteKey))
    }
}
