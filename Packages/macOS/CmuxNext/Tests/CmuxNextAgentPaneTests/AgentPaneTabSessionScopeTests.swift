import Testing
@testable import CmuxNextAgentPane

/// A chat on another machine whose tab names it by another id than acpmux's (a session name, or the
/// id from before the tab was rebound there): the page opens the session that machine's daemon
/// attached (`tabSessionId`), so its prompt, cancel and permission answers must be the pane's too,
/// not refused as `transport.session_not_in_pane`.
@Suite
struct AgentPaneTabSessionScopeTests {
    private static func prompt(_ session: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 9, "method": "session/prompt", "params": ["sessionId": session, "prompt": []]]
    }

    @Test func theSessionARemoteWatchAttachedIsThePanes() {
        let sessions = AcpmuxPaneSessions()
        sessions.add("lane/review")
        #expect(AgentPaneTransport.sessionRefusal(Self.prompt("acp-review-1"), sessions: sessions) != nil)
        sessions.observeTabSession(["id": 3, "result": ["sessions": [], "tabSessionId": "acp-review-1"]], replyTo: "_acpmux/watch")
        #expect(sessions.contains("acp-review-1"))
        #expect(AgentPaneTransport.sessionRefusal(Self.prompt("acp-review-1"), sessions: sessions) == nil)
    }

    @Test func onlyAWatchReplyNamesIt() {
        let sessions = AcpmuxPaneSessions()
        sessions.observeTabSession(["id": 3, "result": ["tabSessionId": "from-attach"]], replyTo: "_acpmux/attach")
        sessions.observeTabSession(["id": 3, "result": ["tabSessionId": ""]], replyTo: "_acpmux/watch")
        sessions.observeTabSession(["method": "_acpmux/watch", "result": ["tabSessionId": "notice"]], replyTo: "_acpmux/watch")
        sessions.observeTabSession(["id": 3, "result": ["tabSessionId": 7]], replyTo: "_acpmux/watch")
        #expect(!sessions.contains("from-attach") && !sessions.contains("") && !sessions.contains("notice"))
        #expect(sessions.isUnstarted)
    }
}
