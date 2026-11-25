import CmuxMobileAgentChat
import Foundation
import CmuxMobileModel
import Testing
@testable import CmuxMobileShell

#if os(iOS)
/// A cmux link opens what it names on the phone (verify/deep-links.md), found by
/// the Mac's public ids in the tree the phone lists.
@MainActor @Suite struct LinkRouteTests {
    let ws = "ws_0123456789abcdef0123456789abcdef"
    let tab = "tab_0123456789abcdef0123456789abcd01"
    let pane = "pane_0123456789abcdef0123456789abcdef"

    var workspaces: [Workspace] {
        var shell = WorkspaceTab(id: "s1", kind: .terminal, title: "zsh")
        shell.linkIDs = .init(tab: "tab_0123456789abcdef0123456789abcd00", pane: pane, isPaneSelected: false)
        var claude = WorkspaceTab(id: "s2", kind: .terminal, title: "claude", harness: "claude")
        claude.linkIDs = .init(tab: tab, pane: pane, isPaneSelected: true, harnessSession: "e8f63fd9")
        var workspace = Workspace(id: "w1", macID: "m", title: "cmux", directory: "/", tabs: [shell, claude], lastActivityAt: Date())
        workspace.resourceID = ws
        return [workspace]
    }

    func resolve(_ text: String, chat: AgentChatDestination? = nil) -> NotificationTarget? {
        guard let link = URL(string: text).flatMap(CmuxLink.init(url:)) else { return nil }
        return NotificationTarget.resolve(link, workspaces: workspaces) { _ in chat }
    }

    @Test func aWorkspaceLinkOpensItsWorkspace() {
        #expect(resolve("cmux://workspace/\(ws)") == .workspace(id: "w1", tabID: nil))
    }

    @Test func aTabLinkOpensItsTab() {
        #expect(resolve("cmux://tab/\(tab)") == .workspace(id: "w1", tabID: "s2"))
        #expect(resolve("https://cmux.com/link/tab/\(tab)") == .workspace(id: "w1", tabID: "s2"))
    }

    @Test func aPaneLinkOpensItsSelectedTab() {
        #expect(resolve("cmux://pane/\(pane)") == .workspace(id: "w1", tabID: "s2"))
    }

    @Test func aSessionOrChiefSubagentLinkOpensItsChat() {
        let chat = AgentChatDestination(workspaceID: "w9", tabID: "s9")
        #expect(resolve("cmux://session/abc", chat: chat) == .chat(chat))
        #expect(resolve("cmux://chief/0a1b2c3d/session/abc", chat: chat) == .chat(chat))
    }

    @Test func anAgentLinkOpensTheTerminalItRunsIn() {
        #expect(resolve("cmux://agent/claude/e8f63fd9") == .workspace(id: "w1", tabID: "s2"))
        #expect(resolve("https://cmux.com/deeplink/agent?harness=claude&session=e8f63fd9&host=a-mac") == .workspace(id: "w1", tabID: "s2"))
    }

    @Test func anAgentLinkNeverOpensAnotherHarnessesTerminal() {
        #expect(resolve("cmux://agent/codex/e8f63fd9") == nil)
    }

    @Test func aHomeConversationLinkOpensTheNamedConversation() {
        #expect(resolve("cmux://conversation/c1/message/m1") == .chief(conversationID: "c1"))
        #expect(resolve("cmux://conversation/c2") == .chief(conversationID: "c2"))
        #expect(resolve("https://cmux.com/link/conversation/c3") == .chief(conversationID: "c3"))
        // The message portion remains an optional scroll anchor; conversation
        // identity is always retained even if no message anchor is shown yet.
        #expect(resolve("cmux://conversation/c4/message/m4") == .chief(conversationID: "c4"))
    }

    @Test func aColdHomeLinkWaitsForItsExactConversation() {
        // No Home identity has loaded yet: a navigation fallback would open
        // the wrong Chief. Once the Mac list arrives, only the named id opens.
        #expect(!NotificationTarget.knowsHomeConversation("target", macChief: nil, cloudChief: nil,
                                                        homeChief: nil, homeRows: []))
        #expect(NotificationTarget.knowsHomeConversation("target", macChief: nil, cloudChief: nil,
                                                       homeChief: nil, homeRows: ["target", "other"]))
        #expect(!NotificationTarget.knowsHomeConversation("missing", macChief: "mac", cloudChief: "cloud",
                                                        homeChief: "mac", homeRows: ["target"]))
        #expect(NotificationTarget.knowsHomeConversation("mac", macChief: "mac", cloudChief: nil,
                                                       homeChief: nil, homeRows: []))
        #expect(NotificationTarget.knowsHomeConversation("cloud", macChief: nil, cloudChief: "cloud",
                                                       homeChief: nil, homeRows: []))
    }

    @Test func aGroupLinkOpensItsWorkspaceOrTheList() {
        #expect(resolve("cmux://group/grp_abcdefghij0123456789/workspace/\(ws)") == .workspace(id: "w1", tabID: nil))
        #expect(resolve("https://cloud-api.cmux.dev/g/grp_abcdefghij0123456789") == .workspaces)
    }

    @Test func aLinkToSomethingThePhoneDoesNotListFindsNothing() {
        #expect(resolve("cmux://tab/tab_ffffffffffffffffffffffffffffffff") == nil)
        #expect(resolve("cmux://session/abc") == nil)
    }
}
#endif
