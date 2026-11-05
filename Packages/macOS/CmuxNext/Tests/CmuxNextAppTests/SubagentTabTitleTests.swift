import CmuxNextActions
@testable import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// Leo 2026-10-30: "subagents shouldn't be tab-named the exact same as the parent". A subagent's
/// pane is a tab on its chat's own session, so the tab strip and the sidebar's tab rows named it by
/// that session, like the chat. It now shows the name its page sent (SubagentTabTitles), while the
/// chat keeps its own, and a name the person gives the tab still wins.
@MainActor
struct SubagentTabTitleTests {
    private static let host = "install:this-mac"

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    @Test func aSubagentsPaneIsNamedAfterTheSubagentNotTheChat() throws {
        let daemon = DaemonService()
        let ref = AgentSessionRef(host: Self.host, session: "s-\(UUID().uuidString)", harness: "claude")
        var chat = TabSnapshot(surface: 1, kind: .conversation, title: "about:blank", url: "about:blank")
        chat.conversation = ConversationTabRef(agentSession: ref)
        var subagent = TabSnapshot(surface: 2, kind: .conversation, title: "about:blank", url: "about:blank")
        subagent.conversation = ConversationTabRef(agentSession: ref)
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [PaneSnapshot(id: 1, tabs: [chat, subagent])])
        daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let chatTab = try #require(daemon.store.tab(surface: 1)), subagentTab = try #require(daemon.store.tab(surface: 2))

        let titles = SubagentTabTitles()
        var strip = TabTitleResolver(newTabPages: [])
        strip.chatTitle = { _ in "claude-sr2-coord" }
        strip.subagentTitle = { titles.title(ofTab: $0.id) }
        #expect(strip.title(subagentTab) == strip.title(chatTab), "fixture: before, the subagent's tab reads like its chat")

        let session = try #require(ref.session)
        titles.name("agent-1", of: session, title: "  Review the tray motion diff \n")
        titles.bind("agent-1", of: session, toTab: subagentTab.id)
        #expect(strip.title(subagentTab) == "Review the tray motion diff")
        #expect(strip.title(chatTab) == "claude-sr2-coord", "the chat lost its own name")
    }

    @Test func onlyANamedSubagentsOpenTabIsRenamed() {
        let titles = SubagentTabTitles()
        // No name sent (an older page, a workflow agent): the tab keeps the chat's name.
        titles.bind("agent-x", of: "s", toTab: "tab-x")
        #expect(titles.title(ofTab: "tab-x") == nil)
        titles.name("agent-y", of: "s", title: "   ")
        titles.bind("agent-y", of: "s", toTab: "tab-y")
        #expect(titles.title(ofTab: "tab-y") == nil, "a blank name renamed the tab")
        // Another session's subagent of the same id is another subagent.
        titles.name("agent-z", of: "s1", title: "One")
        titles.bind("agent-z", of: "s2", toTab: "tab-z")
        #expect(titles.title(ofTab: "tab-z") == nil)
        // A very long name is cut, and closed tabs' names go.
        titles.name("agent-w", of: "s", title: String(repeating: "a", count: 500))
        titles.bind("agent-w", of: "s", toTab: "tab-w")
        #expect(titles.title(ofTab: "tab-w")?.count == SubagentTabTitles.limit)
        titles.name("agent-v", of: "s", title: "Later")
        titles.bind("agent-v", of: "s", toTab: "tab-v") { $0 != "tab-w" }
        #expect(titles.title(ofTab: "tab-w") == nil)
        #expect(titles.title(ofTab: "tab-v") == "Later")
    }

    /// Review of #28497 at 995299ff: a subagent pane shows the chat's other subagents in place, and its
    /// "Subagent of" pill goes back to the chat; the name bound at open stayed on the tab through both.
    @Test func theTabsNameFollowsWhatThePaneShows() {
        let titles = SubagentTabTitles()
        titles.name("reviewer", of: "s", title: "Reviewer")
        titles.bind("reviewer", of: "s", toTab: "tab")
        #expect(titles.title(ofTab: "tab") == "Reviewer")
        titles.show("Auditor", inTab: "tab")
        #expect(titles.title(ofTab: "tab") == "Auditor", "the pane showed another subagent under the first one's name")
        titles.show(nil, inTab: "tab")
        #expect(titles.title(ofTab: "tab") == nil, "back on the chat, the tab kept a subagent's name")
        titles.show("  ", inTab: "tab")
        #expect(titles.title(ofTab: "tab") == nil)
    }

    @Test func identityFollowsThePaneAndClosedTabsReleaseIt() {
        let titles = SubagentTabTitles()
        titles.name("reviewer", of: "s", title: nil, tone: 1)
        titles.bind("reviewer", of: "other", toTab: "other-tab")
        #expect(titles.tone(ofTab: "other-tab") == nil)
        titles.bind("reviewer", of: "s", toTab: "tab")
        #expect(titles.tone(ofTab: "tab") == 1, "an unnamed child still has an identity")
        titles.show("Auditor", inTab: "tab", tone: 3)
        #expect(titles.tone(ofTab: "tab") == 3)
        titles.show(nil, inTab: "tab")
        #expect(titles.tone(ofTab: "tab") == nil, "the parent kept its child's identity")
        titles.show("Invalid", inTab: "tab", tone: 99)
        #expect(titles.tone(ofTab: "tab") == nil)
        titles.show("Reviewer", inTab: "closed", tone: 1)
        titles.bind("reviewer", of: "s", toTab: "new") { $0 != "closed" }
        #expect(titles.tone(ofTab: "closed") == nil)
        #expect(titles.tone(ofTab: "new") == 1)
    }

    @Test func loadingAWorkflowKeepsItsBoundTabNameAndClearsThePreviousChildTone() async {
        let titles = SubagentTabTitles()
        titles.name("workflow", of: "s", title: "Review the patch")
        titles.bind("workflow", of: "s", toTab: "tab")
        let model = AgentPaneModel(host: NoHost(), sessionId: "s")
        model.header = AgentPaneHeaderHooks(run: { _, _ in }, tabState: { AgentPaneHeaderState() }, showsSubagent: { title, tone, keepingTitle in
            titles.show(title, inTab: "tab", tone: tone, keepingTitle: keepingTitle)
        })
        @MainActor func shown(_ params: [String: Any]) async {
            let reply = await model.respondToHeader(AgentPaneRequest(body: ["method": "chat.subagentShown", "params": params]))
            #expect(reply["ok"] as? Bool == true)
        }

        await shown(["subagent": "workflow"])
        #expect(titles.title(ofTab: "tab") == "Review the patch", "loading discarded the name bound when the workflow opened")
        #expect(titles.tone(ofTab: "tab") == nil)
        await shown(["subagent": "child", "title": "Auditor", "tone": 3])
        #expect(titles.title(ofTab: "tab") == "Auditor")
        #expect(titles.tone(ofTab: "tab") == 3)
        await shown(["subagent": "workflow"])
        #expect(titles.title(ofTab: "tab") == "Auditor", "an unknown name must not erase the current bound name")
        #expect(titles.tone(ofTab: "tab") == nil, "the workflow kept the previous child's identity")
        await shown(["subagent": "workflow", "title": "Review the patch"])
        #expect(titles.title(ofTab: "tab") == "Review the patch")
        await shown([:])
        #expect(titles.title(ofTab: "tab") == nil, "returning to the parent kept a child name")
        #expect(titles.tone(ofTab: "tab") == nil)
    }

    @Test func thePageReportsWhatThePaneShows() {
        let shown = AgentPaneRequest(body: ["method": "chat.subagentShown", "params": ["subagent": "a2", "title": "Auditor", "tone": 2]])
        guard case .subagentShown(let agent, let title, let tone) = shown else { Issue.record("not decoded: \(shown)"); return }
        #expect(agent == "a2" && title == "Auditor" && tone == 2)
        let chat = AgentPaneRequest(body: ["method": "chat.subagentShown", "params": [String: Any]()])
        guard case .subagentShown(let none, let noTitle, let noTone) = chat else { Issue.record("not decoded: \(chat)"); return }
        #expect(none == nil && noTitle == nil && noTone == nil, "back on the chat: no subagent, no name")
        let bad = AgentPaneRequest(body: ["method": "chat.subagentShown", "params": ["subagent": ""]])
        if case .subagentShown = bad { Issue.record("an empty subagent id was taken") }
    }

    @Test func thePagesRequestCarriesTheName() throws {
        let request = AgentPaneRequest(body: ["method": "chat.subagentPane", "params": ["subagent": "agent-1", "focus": false, "title": "Audit the stack", "tone": 4]])
        guard case .subagentPane(let agent, let focus, let title, let tone) = request else { Issue.record("not decoded: \(request)"); return }
        #expect(agent == "agent-1" && !focus && title == "Audit the stack" && tone == 4)
        let old = AgentPaneRequest(body: ["method": "chat.subagentPane", "params": ["subagent": "agent-1"]])
        guard case .subagentPane(_, _, let none, let noTone) = old else { Issue.record("not decoded: \(old)"); return }
        #expect(none == nil && noTone == nil, "a page that sends no name still opens the pane")
    }
}
