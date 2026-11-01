import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextDaemon
import Foundation
import Testing

/// A chat opened in a new workspace shows in the open's own turn (P4 instant create), as Cmd-N's New
/// Tab page does: its workspace and its chat tab are in the store before any daemon reply, so the
/// chat's page starts loading at once. They waited for the daemon's creates and the store's mirror
/// first: on a perf mini under load the time from the action to the pane was 67-1992 ms per open
/// (job 0163bd2f, STATUS 3752), on the click path of Open Chat and of `agent.openSessionWorkspace`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChatWorkspaceShowsAtOnceTests {
    /// The workspace `key`'s tabs in the store now.
    private static func tabs(_ key: WorkspaceKey, in store: DaemonStore) -> [TabModel] {
        store.workspaces.first { $0.key == key }.map { $0.screens.flatMap(\.panes).flatMap(\.tabs) } ?? []
    }

    private static func agentTabs(_ services: AppServices) -> AgentTabStore {
        let tabs = services.agentTabs
        tabs.localHost = tabs.localHost ?? AgentSessionRef.host(installID: "chat-at-once-test")
        tabs.holdsTabs = { _ in true }
        return tabs
    }

    @Test func openSessionWorkspaceShowsTheChatBeforeTheDaemonAnswers() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let key = WorkspaceKey.generate()
        let session = "s-at-once-\(UUID().uuidString.prefix(8).lowercased())"

        let work = try AgentSessionWorkspace.open(session: session, name: "lane", key: key, cwd: nil, focus: true, services: services)
        // Same turn as the action: nothing has awaited the daemon yet.
        let atOnce = Self.tabs(key, in: store)
        let failure = await work.value?.message
        let mirrored = await RapidWorkspaceCreateTests.wait(within: .seconds(10)) {
            Self.tabs(key, in: store).contains { !ProvisionalTab.isProvisional(surface: $0.surface) }
        }
        let settled = Self.tabs(key, in: store)
        await launched.stop()

        #expect(atOnce.count == 1, "the action's turn showed \(atOnce.count) tabs of the new workspace (none: it waited for the daemon)")
        #expect(atOnce.first?.kind == .conversation)
        #expect(atOnce.first?.agentSession?.session == session, "the stand-in names the session, so its page opens that chat")
        #expect(failure == nil, "refused: \(failure ?? "")")
        #expect(mirrored, "the daemon's tab never took the stand-in over")
        #expect(settled.count == 1, "the daemon's tab replaced the stand-in in place: \(settled.map(\.surface))")
        #expect(settled.first?.agentSession?.session == session)
    }

    /// The stand-in can be closed before the daemon answers (an agent opened a chat; the person closes its row at
    /// once). That close runs after the daemon's create, in the same lane, so it closes what the daemon made: no
    /// workspace and no tab are left, in the store or the daemon, and the row does not come back. Without the lane the
    /// close was sent for a workspace the daemon did not have yet, failed, and the daemon's create then listed it again.
    @Test func aCloseOfTheStandInBeforeTheDaemonAnswersLeavesNothing() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let key = WorkspaceKey.generate()
        let session = "s-close-\(UUID().uuidString.prefix(8).lowercased())"

        let work = try AgentSessionWorkspace.open(session: session, name: "closed lane", key: key, cwd: nil, services: services)
        let standIn = store.workspaces.contains { $0.key == key }
        // Same turn: the daemon has not answered the create yet.
        let ran = services.registry.perform("closeWorkspace", invocation: ActionInvocation(target: ActionTargetRef(kind: .workspace, id: key.rawValue)))
        _ = await work.value
        let gone = await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { !store.workspaces.contains { $0.key == key } }
        // Long enough for a create the close missed to list again, then the store caught up with the daemon.
        try await Task.sleep(for: .seconds(2))
        if let connection = services.daemon.connection, let barrier = await connection.eventSequence() {
            await RapidWorkspaceCreateTests.wait(within: .seconds(10)) { store.appliedSequence >= barrier }
        }
        let back = store.workspaces.filter { $0.key == key }
        let tabLeft = tabs.tab(showing: session, host: tabs.localHost)
        await launched.stop()

        try #require(standIn, "the open showed no stand-in to close")
        #expect(ran, "Close Workspace refused the stand-in")
        #expect(gone, "the workspace never left after its close")
        #expect(back.isEmpty, "the closed workspace is listed again (the daemon's create outlived the close): \(back.map(\.id))")
        #expect(tabLeft == nil, "a chat tab on the session is left: \(tabLeft ?? "")")
    }

    @Test func openChatShowsItsWorkspaceBeforeTheDaemonAnswers() async throws {
        let launched = try await RapidWorkspaceCreateTests.launch()
        let services = launched.services
        let tabs = Self.agentTabs(services)
        try #require(tabs.canHostChat, "this build has no agent page")
        let store = services.daemon.store
        let window = try #require(services.windows.active?.state.id)
        let before = Set(store.workspaces.map(\.id))
        var spawn = WorkspaceSpawn(name: "past chat")
        spawn.firstChat = AgentPaneSeed(cwd: "/tmp", pastChat: "claude-code:at-once")

        // Open Chat's path (ChatsOpenCoordinator.createWorkspace): the create starts in this turn.
        let work = services.windows.startWorkspace(spawn, into: window)
        let atOnce = store.workspaces.filter { !before.contains($0.id) }.flatMap { $0.screens.flatMap(\.panes).flatMap(\.tabs) }
        let created = try? await work()
        await launched.stop()

        #expect(atOnce.count == 1, "the open's turn showed \(atOnce.count) chat tabs (none: it waited for the daemon)")
        #expect(atOnce.first?.kind == .conversation)
        #expect(created != nil, "the daemon's create failed")
    }
}
