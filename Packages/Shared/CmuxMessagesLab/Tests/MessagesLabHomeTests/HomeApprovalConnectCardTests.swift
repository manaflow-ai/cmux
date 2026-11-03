import CmuxAgentQuestion
import Foundation
import Testing
@testable import MessagesLabHome

/// An agent's MCP connect card in Home (optchat-chief brain/home_mcp_connect.rs) is a Home approval
/// whose permission is `mcp-connect:<requestId>`: the card shows the server's facts from the
/// request, and its answer reads Connected or Not connected, not Allowed or Denied.
@MainActor @Suite struct HomeApprovalConnectCardTests {
    static let requestJSON = #"{"toolCall":{"title":"Connect the MCP server Linear","rawInput":{"server":"https://mcp.linear.app/mcp","scope":"chief"},"_meta":{"acpmux":{"mcpConnect":{"requestId":"r-1","scope":"chief"}}}},"options":[{"optionId":"allow","kind":"allow_once"},{"optionId":"deny","kind":"reject_once"}]}"#

    static func question(permission: String, state: AgentQuestion.State = .pending) -> AgentQuestion {
        AgentQuestion(id: "home-approval-\(permission)",
                      source: .init(harness: .chief, session: "local/test-subagent", permission: permission),
                      items: [.init(id: "approval:" + String(repeating: "a", count: 64), prompt: "a1: Connect the MCP server Linear",
                                    options: [.init(id: "allow", label: "Connect", preview: .init(text: requestJSON)),
                                              .init(id: "deny", label: "Don't connect")], allowsOther: false)],
                      state: state)
    }

    @Test func aConnectCardShowsTheServerAndItsScope() {
        let question = Self.question(permission: "mcp-connect:r-1")
        #expect(HomeApprovalRowProvider.isConnect(question))
        #expect(!HomeApprovalRowProvider.isConnect(Self.question(permission: "perm-1")))
        let text = HomeApprovalRowProvider.text(.init(question: question, local: .init()))
        #expect(text.contains("https://mcp.linear.app/mcp"))
        #expect(text.contains("chief"))
    }

    @Test func anAnsweredConnectCardSaysConnectedOrNotConnected() {
        let item = "approval:" + String(repeating: "a", count: 64)
        let answer = { (option: String) in
            AgentQuestion.State.answered(AgentQuestionAnswer(selections: [item: .init(optionIDs: [option])]))
        }
        let connected = HomeApprovalRowProvider.text(.init(question: Self.question(permission: "mcp-connect:r-1", state: answer("allow")), local: .init()))
        #expect(connected.hasSuffix(CmuxStrings.approvalConnected))
        let declined = HomeApprovalRowProvider.text(.init(question: Self.question(permission: "mcp-connect:r-1", state: answer("deny")), local: .init()))
        #expect(declined.hasSuffix(CmuxStrings.approvalNotConnected))
        let allowed = HomeApprovalRowProvider.text(.init(question: Self.question(permission: "perm-1", state: answer("allow")), local: .init()))
        #expect(allowed.hasSuffix(CmuxStrings.approvalAllowed))
    }
}
