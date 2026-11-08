import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextControl
@testable import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextLayout
import Foundation
import Testing

/// #32989: a Chief prompted from one window created its workspaces (`cmux workspace create`,
/// `cmux agents workspace create`) in another: the daemon has no windows, and the app gave every
/// create it did not make itself to the most recent window. The CLI now announces the create
/// (`workspace.expect_window`, keyed by its idempotency key) and the app files the workspace into
/// that window as the daemon reports it, without changing what that window shows.
@MainActor @Suite(.serialized)
struct CreateInCallerWindowTests {
    private static func workspace(_ key: String, surface: UInt64) -> WorkspaceSnapshot {
        let pane = PaneSnapshot(id: PaneID(rawValue: surface), tabs: [TabSnapshot(surface: SurfaceID(rawValue: surface), title: key)])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: surface), layout: .leaf(pane.id), panes: [pane])
        return WorkspaceSnapshot(id: WorkspaceHandle(rawValue: surface), key: WorkspaceKey(rawValue: key), name: key, screens: [screen])
    }

    private static func tree(_ keys: [String]) -> DaemonTree {
        var tree = DaemonTree(registryID: "s-local", workspaceRevision: 10, workspaces: keys.enumerated().map { workspace($1, surface: UInt64($0 + 1)) })
        tree.personal = PersonalState(workspaces: keys.enumerated().map {
            PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: $1), index: $0)
        })
        return tree
    }

    /// Two windows; returns the one the most recent rule would NOT pick, and the other.
    private static func twoWindows(_ services: AppServices) async throws -> (prompted: WindowController, other: WindowController) {
        let store = services.machines.local.store
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(#"{"app":"cmux-tui","protocol":1,"session":"s-local","generation":"g1"}"#.utf8))
        store.noteHandshake(identity)
        store.connectionState = .connected(identity)
        store.apply(snapshot: Self.tree(["ws-a", "ws-b"]))
        let a = try #require(services.windows.openWindow(workspaces: ["ws-a"], frame: CGRect(x: 100, y: 100, width: 900, height: 600)))
        let b = try #require(services.windows.openWindow(workspaces: ["ws-b"], frame: CGRect(x: 300, y: 300, width: 900, height: 600)))
        for _ in 0..<200 where a.state.workspaceID != "ws-a" || b.state.workspaceID != "ws-b" { try await Task.sleep(for: .milliseconds(10)) }
        let recent = try #require(services.windows.registry.value.mostRecentOpen())
        return recent == a.state.id ? (b, a) : (a, b)
    }

    private static func added(_ key: String, surface: UInt64, mutation: String) -> DaemonEvent {
        .workspaceAdded(WorkspaceDelta(workspace: WorkspaceHandle(rawValue: surface), index: 2, entity: workspace(key, surface: surface),
                                       workspaceRevision: 11, origin: DaemonStore.resourceAPIOrigin, mutationID: mutation))
    }

    /// Applies the workspace-added delta of `id` and returns the claim membership reconcile sees for it
    /// as it runs (the window it is filed into, and whether quietly): the store names the create's key
    /// before its list hook, which runs reconcile.
    private static func reconciledClaim(_ id: String, surface: UInt64, mutation: String,
                                        _ services: AppServices) throws -> (window: String?, quiet: Bool) {
        let store = services.machines.local.store
        // The membership loop installs the store's hooks on its first pass; run that pass now.
        if store.onWorkspaceListChanged == nil { services.windows.reconcileMembership() }
        let reconcile = try #require(store.onWorkspaceListChanged, "membership installed no list hook")
        var seen: (window: String?, quiet: Bool) = (nil, false)
        store.onWorkspaceListChanged = {
            seen = (services.windows.claims.pending[id], services.windows.claims.quiet.contains(id))
            reconcile()
        }
        defer { store.onWorkspaceListChanged = reconcile }
        store.apply(added(id, surface: surface, mutation: mutation))
        return seen
    }

    @Test func anAnnouncedCreateOpensInItsWindowNotTheMostRecent() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        let reply = try services.windows.expectCreate(["idempotency_key": "cli-key-1", "window": .string(prompted.state.id)], topology: ControlSnapshotPublisher.topology(services))
        #expect(reply["window"] == .string(ControlWindowInfo.publicID(forKey: prompted.state.id)))
        // A terminal create (the CLI default): the daemon names its workspace `<key>/workspace`.
        let claim = try Self.reconciledClaim("ws-new", surface: 3, mutation: "cli-key-1" + DaemonStore.workspaceReservationSuffix, services)
        #expect(claim.window == prompted.state.id, "it went to \(claim.window ?? "the most recent window"), not the window it was announced for")
        #expect(claim.quiet, "an agent's create would change what the window shows")
        #expect(prompted.state.workspaceID == "ws-a", "an agent's create changed what the window shows")
    }

    @Test func aChiefTurnsCreateOpensInThePromptedWindow() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        // The person sent the Chief a message from the window the most recent rule would not pick.
        services.windows.chiefPrompt.note(prompted.state.id, conversation: "chief")
        let topology = ControlSnapshotPublisher.topology(services)
        #expect(topology.chiefPromptWindowID == prompted.state.id)
        _ = try services.windows.expectCreate(["idempotency_key": "turn-key", "caller": ["home_chat": true]], topology: topology)
        #expect(try Self.reconciledClaim("ws-turn", surface: 3, mutation: "turn-key", services).window == prompted.state.id)
    }

    @Test func anUnannouncedCreateStillGoesToTheMostRecentWindow() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        // No claim: reconcile's most recent window, as before.
        #expect(try Self.reconciledClaim("ws-plain", surface: 3, mutation: "someone-else", services).window == nil)
    }

    @Test func aNamedWindowTheAppDoesNotHaveIsRefused() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }

        #expect(throws: ControlError.self) {
            try services.windows.expectCreate(["idempotency_key": "k", "window": "win_00000000000000000000000000000000"], topology: ControlSnapshotPublisher.topology(services))
        }
    }
    /// The create actions a Chief turn can run (`workspace.newAtTop`, `newBelow`, `newOnMachine`, a group's
    /// new workspace, `agent.openSessionWorkspace`) take the caller's window and the workspace it shows,
    /// not the active window's; a person's run (no caller window) keeps the active window.
    @Test func aCallersCreateActionsUseItsWindowNotTheActiveOne() async throws {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let (prompted, other) = try await Self.twoWindows(services)
        defer { for controller in [prompted, other] { controller.teardown(); controller.window?.close() } }
        let context = AppActionContext(services: services)

        var chief = ActionInvocation(origin: .cli)
        chief.callerWindow = prompted.state.id
        #expect(context.createWindow(chief)?.state.id == prompted.state.id)
        #expect(try context.createAnchor(chief).id == prompted.state.workspaceID, "a Chief's create was placed next to another window's workspace")

        // A named target still wins over the caller's window.
        var targeted = ActionInvocation(origin: .cli)
        targeted.callerWindow = prompted.state.id
        let otherWorkspace = try #require(other.state.workspaceID)
        targeted.target = ActionTargetRef(kind: .workspace, id: otherWorkspace)
        #expect(try context.createAnchor(targeted).id == otherWorkspace)

        // A closed caller window, or none: the active window, as before.
        var gone = ActionInvocation(origin: .cli)
        gone.callerWindow = "window-that-closed"
        #expect(context.createWindow(gone)?.state.id == services.windows.active?.state.id)
        #expect(context.createWindow(ActionInvocation())?.state.id == services.windows.active?.state.id)
    }

    /// A message to the Chief that no window's Home transcript sent (the phone, another Mac, New Message, an
    /// action) means no window prompted that turn: its workspaces go to the most recent window again.
    @Test func aMessageFromElsewhereStopsNamingThePromptedWindow() {
        typealias Last = ChiefPromptWindow.Last
        let prompt = ChiefPromptWindow()
        prompt.observe(["chief": Last(message: "m0", byPerson: true)]) // launch: the baseline
        prompt.note("window-a", conversation: "chief")
        prompt.note("window-a", conversation: "chief") // two quick sends
        prompt.observe(["chief": Last(message: "m1", byPerson: true)])
        prompt.observe(["chief": Last(message: "m2", byPerson: true)])
        #expect(prompt.id == "window-a", "the window's own second send cleared it")
        prompt.observe(["chief": Last(message: "r1", byPerson: false)]) // the Chief replied
        prompt.observe(["chief": Last(message: "t1", byPerson: false)]) // a teammate wrote
        #expect(prompt.id == "window-a")
        prompt.observe(["chief": Last(message: "m3", byPerson: true)]) // sent from the phone
        #expect(prompt.id == nil, "a message from elsewhere kept the old prompting window")
        // A send whose own message the store skipped (the reply came in the same pass) is settled by the reply.
        prompt.note("window-b", conversation: "chief")
        prompt.observe(["chief": Last(message: "r2", byPerson: false)])
        prompt.observe(["chief": Last(message: "m5", byPerson: true)])
        #expect(prompt.id == nil)
        // A send to another Chief conversation does not account for a message here.
        prompt.note("window-c", conversation: "named-chief")
        prompt.observe(["chief": Last(message: "m6", byPerson: true)])
        #expect(prompt.id == nil)
    }

    /// Each Chief conversation's last message, and whether this app's person wrote it; other chats are not read.
    @Test func lastMessagesAreReadFromChiefConversationsOnly() {
        let person = ConversationParticipant(id: ConversationParticipant.localUserID, kind: .human, displayName: "Me")
        let mux = ConversationParticipant(id: "agent_mux", kind: .agent, displayName: "Chief", agentClass: "mux")
        let friend = ConversationParticipant(id: "user_friend", kind: .human, displayName: "Friend")
        func message(_ id: String, by author: String, in conversation: String) -> ConversationMessage {
            ConversationMessage(id: id, conversation: conversation, seq: 1, clientMsgID: id, author: author, parts: [], createdAt: "2026-11-06T00:00:00.000Z")
        }
        func summary(_ id: String, _ participants: [ConversationParticipant], last: ConversationMessage) -> CmuxNextDaemon.ConversationSummary {
            .init(id: id, title: id, participants: participants, lastSeq: 1, rev: 1, createdAt: "2026-11-06T00:00:00.000Z",
                  updatedAt: "2026-11-06T00:00:00.000Z", lastMessage: last)
        }
        let lasts = HomeChiefName.lastMessages(in: [
            summary("chief", [person, mux], last: message("asked", by: person.id, in: "chief")),
            summary("chief-replied", [person, mux], last: message("reply", by: mux.id, in: "chief-replied")),
            summary("channel", [person, friend, mux], last: message("hey", by: friend.id, in: "channel")),
            summary("dm", [person, friend], last: message("hi", by: person.id, in: "dm")),
        ], me: person.id)
        #expect(lasts.map { "\($0.conversation)=\($0.message):\($0.byPerson)" }.sorted()
            == ["channel=hey:false", "chief-replied=reply:false", "chief=asked:true"])
    }
}
