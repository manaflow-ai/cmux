import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Lawrence, 2026-10-21: "This chat isn't available" showed too often to tell why. The page
/// reports each view (`chat.missing {session, reason}`) and the host logs it, so the views can be
/// counted by chat and reason.
@MainActor
struct AgentPaneMissingChatRequestTests {
    @Test func decodesTheReport() {
        let request = AgentPaneRequest(body: ["method": "chat.missing",
                                              "params": ["session": "01a1201b-d3c3", "reason": "notListedAtOpen"]])
        #expect(request == .missingChat(session: "01a1201b-d3c3", reason: "notListedAtOpen"))
        #expect(AgentPageOps.methods["chat.missing"] == "chat.missing")
        #expect(String(describing: request) == "missingChat")
        // An older page that sends no reason still counts.
        #expect(AgentPaneRequest(body: ["method": "chat.missing", "params": ["session": "s"]])
            == .missingChat(session: "s", reason: "unknown"))
    }

    @Test func refusesAReportWithoutASession() {
        #expect(AgentPaneRequest(body: ["method": "chat.missing", "params": ["reason": "notListedAtOpen"]])
            == .unsupported("chat.missing"))
    }
}
