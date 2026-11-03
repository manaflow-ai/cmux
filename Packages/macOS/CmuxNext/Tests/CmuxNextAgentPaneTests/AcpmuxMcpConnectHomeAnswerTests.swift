import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Home's MCP connect card (optchat-chief brain/home_mcp_connect.rs) carries acpmux's request id
/// and the agent's scope in its snapshot; the app answers with exactly those, and refuses a
/// snapshot that names no card or a scope acpmux does not know.
@Suite struct AcpmuxMcpConnectHomeAnswerTests {
    static func snapshot(_ connect: [String: Any]) throws -> String {
        let request: [String: Any] = [
            "toolCall": ["title": "Connect the MCP server Linear", "_meta": ["acpmux": ["mcpConnect": connect]]],
            "options": [["optionId": "allow", "kind": "allow_once"], ["optionId": "deny", "kind": "reject_once"]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    }

    @Test func theCardsRequestIdAndScopeComeFromItsSnapshot() throws {
        let parsed = try #require(AcpmuxApprovalAnswerer.mcpConnect(try Self.snapshot(["requestId": "r-1", "scope": "chief"])))
        #expect(parsed.requestID == "r-1")
        #expect(parsed.scope == "chief")
        #expect(AcpmuxApprovalAnswerer.requestDigest(try Self.snapshot(["requestId": "r-1", "scope": "chief"])) != nil)
    }

    @Test(arguments: [
        ["requestId": "r-1", "scope": "somewhere"],
        ["requestId": "", "scope": "chat"],
        ["scope": "chat"],
    ])
    func aSnapshotWithoutAKnownCardIsRefused(_ connect: [String: String]) throws {
        #expect(AcpmuxApprovalAnswerer.mcpConnect(try Self.snapshot(connect)) == nil)
    }
}
