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
