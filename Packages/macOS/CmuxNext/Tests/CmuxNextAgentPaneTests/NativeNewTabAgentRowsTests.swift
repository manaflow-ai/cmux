@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The native New Tab page (`tabs.nativeNewTabPage`) lists the web page's agent rows (Lawrence
/// 2026-11-15: "show the new rows in the native Swift New Tab page too"): the chats its text finds
/// and "Start <agent> in <folder>" rows, by the web page's rules (webviews newtab/launchRows.ts).
@MainActor
struct NativeNewTabAgentRowsTests {
    private static let home = "/Users/me"
    private static let folders = ["/Users/me/fun/cmux", "/Users/me/fun/cmux-tui", "/Users/me/notes"]

    private static func page(workspaces: [AgentPaneOmnibar.Workspace] = []) -> AgentPaneNewTab {
        AgentPaneNewTab(kind: .agent, omnibar: AgentPaneOmnibar(workspaces: workspaces), projects: folders,
                        lastAgent: "claude", home: home)
    }

    private static func chat(_ key: String, _ title: String, _ at: TimeInterval) -> AgentPaneDeviceChat {
        AgentPaneDeviceChat(key: key, harness: "codex", title: title, updatedAt: Date(timeIntervalSince1970: at))
    }

    private static func ids(_ text: String, page: AgentPaneNewTab = page(), chats: [AgentPaneDeviceChat] = []) -> [String] {
        let model = NativeNewTabModel(page: page, actions: NativeNewTabActions())
        model.chats = chats
        model.text = text
        return model.rows.map(\.id)
    }

    @Test func anAgentsNameAndAFolderWordLeadAboveAsk() {
        #expect(Self.ids("codex cmux") == ["start:codex:/Users/me/fun/cmux", "start:codex:/Users/me/fun/cmux-tui", "ask"])
        #expect(Self.ids("codex in ~/fun/cmux").first == "start:codex:/Users/me/fun/cmux")
    }

    @Test func aWordThatNamesAFolderOffersTheLastAgentThereUnderAsk() {
        #expect(Self.ids("notes") == ["ask", "start:claude:/Users/me/notes"])
    }

    @Test func aPromptAfterAnAgentsNameStaysAPrompt() {
        #expect(Self.ids("claude why is the build slow") == ["ask"])
        // A word that only starts a folder's name may be a one-word prompt: Ask keeps Return.
        #expect(Self.ids("claude cmu").first == "ask")
        // A prefix names no agent to lead with.
        #expect(Self.ids("cla").first == "ask")
    }

    @Test func anExactWorkspaceNameKeepsReturn() {
        let rows = Self.ids("codex", page: Self.page(workspaces: [AgentPaneOmnibar.Workspace(id: "w1", name: "codex")]))
        #expect(rows.first == "ask")
        #expect(rows.contains("workspace:w1"))
        #expect((rows.firstIndex(of: "workspace:w1") ?? 99) < (rows.firstIndex { $0.hasPrefix("start:") } ?? -1))
    }

    @Test func aSlashCommandListsNoStart() {
        #expect(!Self.ids("/model").contains { $0.hasPrefix("start:") })
        #expect(Self.ids("~/fun/cmux").contains("start:claude:/Users/me/fun/cmux"))
    }

    @Test func chatsAreSearchedByTitleNewestFirst() {
        let chats = [Self.chat("codex:a", "Fix the omnibar ranking", 1), Self.chat("codex:b", "Omnibar perf", 2),
                     Self.chat("codex:c", "Unrelated", 3)]
        #expect(Self.ids("omni", chats: chats) == ["ask", "chat:codex:b", "chat:codex:a"])
        // Two letters find a chat only at a word's start.
        #expect(!Self.ids("ni", chats: chats).contains { $0.hasPrefix("chat:") })
    }

    @Test func aPickRunsTheStartOrOpensTheChat() {
        var log: [String] = []
        let actions = NativeNewTabActions(openChat: { log.append("open \($0)") }, start: { log.append("start \($0) \($1)") })
        let model = NativeNewTabModel(page: Self.page(), actions: actions)
        model.chats = [Self.chat("codex:a", "Omnibar perf", 1)]
        model.text = "codex cmux"
        model.commit()
        model.text = "omnibar"
        model.move(1)
        model.commit()
        #expect(log == ["start codex /Users/me/fun/cmux", "open codex:a"])
    }

    @Test func aStartRowShowsTheAgentAndTheFolderUnderHome() {
        let row = NativeNewTabRow.start(NativeNewTabStart(harness: "codex", agent: "Codex", folder: "/Users/me/fun/cmux"))
        #expect(NativeNewTabRowContent(row, strings: NativeNewTabStrings(), home: Self.home).title == "Codex in ~/fun/cmux")
    }

    @Test func theRowsStayWithinTheLimit() {
        let chats = (0..<6).map { Self.chat("codex:\($0)", "cmux chat \($0)", TimeInterval($0)) }
        let workspaces = (0..<6).map { AgentPaneOmnibar.Workspace(id: "w\($0)", name: "cmux \($0)") }
        let rows = Self.ids("cmux", page: Self.page(workspaces: workspaces), chats: chats)
        #expect(rows.count <= NativeNewTabRanker().limit)
        #expect(rows.contains { $0.hasPrefix("workspace:") } && rows.contains { $0.hasPrefix("chat:") } && rows.contains { $0.hasPrefix("start:") })
    }
}
