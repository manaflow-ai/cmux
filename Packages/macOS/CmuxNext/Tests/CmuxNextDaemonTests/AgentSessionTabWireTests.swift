import Foundation
import Testing
@testable import CmuxNextDaemon

/// Agent chat tabs are store tabs (cmux-tui/spec/commands.md, new-conversation-tab): a
/// `conversation` tab whose source is an acpmux session (`agent-session-tabs-v1`)
/// instead of a `conv_` conversation. The app reads the source from the tree.
@Suite struct AgentSessionTabWireTests {
    private static let agentTab = #"""
    {"surface":8,"tab_resource_id":"tab_0123456789abcdef0123456789abcdef","kind":"conversation",
     "browser_renderer":"frontend",
     "conversation":{"agent_session":{"host":"install:mac-1","session":"s-1","harness":"claude"}}}
    """#

    @Test func anAgentSessionTabDecodesItsSource() throws {
        let tab = try JSONDecoder().decode(TabSnapshot.self, from: Data(Self.agentTab.utf8))
        #expect(tab.kind == .conversation)
        #expect(tab.conversation != nil, "the agent session source is a conversation tab record")
        #expect(tab.isFrontendOwned)
    }

    /// A new chat has no session yet: the record still decodes.
    @Test func aNewChatWithoutASessionDecodes() throws {
        let line = #"""
        {"surface":9,"kind":"conversation","browser_renderer":"frontend",
         "conversation":{"agent_session":{"host":"install:mac-1","session":null,"harness":null}}}
        """#
        let tab = try JSONDecoder().decode(TabSnapshot.self, from: Data(line.utf8))
        #expect(tab.conversation != nil)
    }
}

/// The session bind is a compare-and-swap: it always names the session it expects (null for
/// a tab with none), so a chat changed elsewhere is refused instead of overwritten.
@Suite struct AgentSessionBindWireTests {
    @Test func theBindAlwaysNamesTheExpectedSession() throws {
        let data = try WireCoding.encodeRequest(BindConversationTabSessionRequest(surface: 3, session: "s-2"), id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        #expect(object["cmd"] == .string("bind-conversation-tab-session"))
        #expect(object["session"] == .string("s-2"))
        #expect(object["expected_session"] == .null, "an unbound tab expects null, sent explicitly")
    }
}
