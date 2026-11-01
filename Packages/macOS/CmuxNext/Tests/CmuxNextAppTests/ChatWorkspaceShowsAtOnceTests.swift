import AppKit
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
