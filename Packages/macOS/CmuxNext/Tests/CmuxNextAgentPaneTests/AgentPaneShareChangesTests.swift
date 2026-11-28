@testable import CmuxNextAgentPane
import CmuxNextSettings
import Foundation
import Testing

/// An open Share dialog hears its chat's share changes: the page gets `shareChanged` with the chat's
/// acpmux session (webviews share/shareChanges.ts), on the page host and the legacy bridge alike.
@MainActor
struct AgentPaneShareChangesTests {
    @Test func theEventNamesTheChatsSession() {
        let event = AgentPaneShareChanges.event("acp_1")
        #expect(event.kind == "shareChanged")
        #expect(event.value == .string("acp_1"))
    }

    @Test func theLegacyScriptPassesTheSessionAsJSON() {
        #expect(AgentPaneShareChanges.script(#"acp_"1"#) == #"window.cmuxAcpmuxBridge?.applyShareChanged?.("acp_\"1");"#)
    }
}
