import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextWorkspaceNaming
import Testing

/// Name from Activity sends only titles and short snippets of a workspace's tabs to the cheapest
/// model and keeps at most five words of its reply.
@MainActor
struct WorkspaceActivityNameTests {
    private static let host = "install:activity-name"

    @Test func itAsksHaikuAndFallsBackToTheDefaultHarnessesSmallModel() {
        let activity = WorkspaceActivityName(tabs: [.browser(title: "Docs")])
        #expect(activity.completionParams["model"] as? String == "claude-haiku-5-5")
        #expect(activity.completionParams["harness"] as? String == "claude")
        // No harness and no model: acpmux runs the default harness on its own small model.
        #expect(activity.completionFallbackParams["harness"] == nil)
        #expect(activity.completionFallbackParams["model"] == nil)
        #expect(activity.completionFallbackParams["prompt"] as? String == activity.prompt)
    }

    @Test func readsChatTitlesNewestPromptsFoldersAndPageTitles() {
        let turns = AgentTurnStateStore()
        turns.localHost = Self.host
        for (index, prompt) in ["First ask", "Second ask", "Third ask", "Fourth ask"].enumerated() {
            let start = UInt64(index + 1) * 1_000
            turns.apply(session: "s1", state: .working, lastMessage: nil, muted: false, title: "Fix login",
                        generatedTitle: "Fix login", detail: AgentChatDetail(turnStartedAtMs: start, prompt: prompt, laneSinceMs: start))
            turns.apply(session: "s1", state: nil, lastMessage: nil, muted: false, title: "Fix login",
                        generatedTitle: "Fix login", detail: nil)
        }
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: Self.host, session: "s1", harness: "claude"))
        let terminal = TabSnapshot(surface: 2, terminalID: "20", kind: .pty, title: "npm test", cwd: "/Users/me/web")
        let page = TabSnapshot(surface: 3, kind: .browser, title: "ignored")
        let pane = PaneSnapshot(id: 1, tabs: [chat, terminal, page])
        let workspace = WorkspaceModel(WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "activity"), name: "workspace-1",
                                                         screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])]))

        let activity = WorkspaceActivityName.read(workspace, turns: turns) { _ in "Login · Docs" }
        #expect(activity.tabs == [
            .chat(title: "Fix login", prompts: ["Second ask", "Third ask", "Fourth ask"]),
            .terminal(folder: "/Users/me/web", title: "npm test"),
            .browser(title: "Login · Docs"),
        ])
        #expect(activity.prompt.hasSuffix("""
        Tabs:
        - Agent chat: Fix login
          - asked: Second ask
          - asked: Third ask
          - asked: Fourth ask
        - Terminal in /Users/me/web: npm test
        - Web page: Login · Docs
        """))
    }

    @Test func emptyTabsAreDroppedAndAnIncognitoPageSendsNothing() {
        let activity = WorkspaceActivityName(tabs: [.browser(title: nil), .chat(title: nil, prompts: []), .terminal(folder: nil, title: nil)])
        #expect(activity.isEmpty)
    }

    @Test func thePromptStaysUnderTheCompletionLimit() {
        let prompts = Array(repeating: String(repeating: "界", count: WorkspaceActivityName.snippetLimit), count: 3)
        let activity = WorkspaceActivityName(tabs: Array(repeating: .chat(title: "Chat", prompts: prompts), count: 12))
        #expect(activity.prompt.utf8.count <= WorkspaceActivityName.promptByteLimit)
        #expect(activity.prompt.contains("- Agent chat: Chat"))
    }

    @Test func snippetsAreOneShortLine() throws {
        let long = String(repeating: "word ", count: 60)
        let snippet = try #require(WorkspaceActivityName.snippet("a\n\n  b \t" + long))
        #expect(snippet.hasPrefix("a b word"))
        #expect(snippet.count == WorkspaceActivityName.snippetLimit)
        #expect(snippet.hasSuffix("…"))
        #expect(WorkspaceActivityName.snippet("  \n ") == nil)
    }

    @Test func theReplyKeepsItsFirstLineWithoutQuotesLabelsOrExtraWords() {
        #expect(WorkspaceActivityName.name(fromReply: "\"Login Bug Fix\"\n\nThis workspace is about…") == "Login Bug Fix")
        #expect(WorkspaceActivityName.name(fromReply: "Name: Release notes draft.") == "Release notes draft")
        #expect(WorkspaceActivityName.name(fromReply: "**Sidebar drag polish**") == "Sidebar drag polish")
        #expect(WorkspaceActivityName.name(fromReply: "one two three four five six seven") == "one two three four five")
        #expect(WorkspaceActivityName.name(fromReply: " \n\"\" ") == nil)
    }

    private static func workspace(pages count: Int, revision: UInt64 = 1) -> WorkspaceModel {
        let tabs = (1...count).map { TabSnapshot(surface: SurfaceID(rawValue: UInt64($0)), kind: .browser, title: "page \($0)") }
        let pane = PaneSnapshot(id: 1, tabs: tabs)
        return WorkspaceModel(WorkspaceSnapshot(id: 1, key: WorkspaceKey(rawValue: "activity"), name: "workspace-1",
                                                nameSource: .auto, nameRevision: revision,
                                                screens: [ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])]))
    }

    @Test func aCrowdedWorkspaceReadsOnlyTheTabLimit() {
        var asked = 0
        let activity = WorkspaceActivityName.read(Self.workspace(pages: 40), turns: AgentTurnStateStore()) { tab in
            asked += 1
            return tab.titleText
        }
        #expect(activity.tabs.count == WorkspaceActivityName.tabLimit)
        #expect(asked == WorkspaceActivityName.tabLimit, "the walk stops at the limit instead of reading every tab")
    }

    @MainActor
    private final class Host: WorkspaceActivityNameHost {
        let workspace: WorkspaceModel
        var guards: Bool
        var pagesAsked = 0
        var completions = 0
        init(_ workspace: WorkspaceModel, guards: Bool) {
            self.workspace = workspace
            self.guards = guards
        }
        func activityWorkspace(_ invocation: ActionInvocation) -> WorkspaceModel? { workspace }
        func activityPageTitle(_ tab: TabModel) -> String? { pagesAsked += 1; return tab.titleText }
        func activityHasAgents() -> Bool { true }
        func activityComplete(_ params: [String: any Sendable], fallback: [String: any Sendable]) async throws -> String { completions += 1; return "Name" }
        func activityRun(_ workspace: WorkspaceModel, _ body: @escaping @Sendable (isolated DaemonConnection) async throws -> Void) async -> Bool { true }
        func activityGuardsRevision(_ workspace: WorkspaceModel) -> Bool { guards }
    }

    @Test func aDaemonWithoutTheRevisionGuardIsRefusedBeforeAnythingIsRead() {
        let host = Host(Self.workspace(pages: 2), guards: false)
        _ = WorkspaceActivityNameActions(host: host, turns: AgentTurnStateStore()).effect(ActionInvocation())
        #expect(host.pagesAsked == 0, "no tab is read for a rename the daemon cannot guard")
        #expect(host.completions == 0)

        let guarded = Host(Self.workspace(pages: 2), guards: true)
        _ = WorkspaceActivityNameActions(host: guarded, turns: AgentTurnStateStore()).effect(ActionInvocation())
        #expect(guarded.pagesAsked == 2)
    }
}
