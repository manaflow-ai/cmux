import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The relay's `_acpmux/status` filter (``AcpmuxPaneMethods/replyShapes``): the page's environment
/// picker sorts peers into SSH and Cloud by transport, so each peer keeps its name and the scheme
/// of its URL, never the URL itself (which can carry a user or a token).
struct AgentPaneStatusReplyShapeTests {
    static func reply(_ result: [String: Any]) throws -> [String: Any] {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/status"])
        let text = AcpmuxPaneMethods.filteredReply(["result": result], shape: shape, pageID: "7")
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func eachPeerKeepsItsNameAndTransportButNotItsURL() throws {
        let reply = try Self.reply(["peers": [
            ["name": "gpu-box", "url": "ssh://dev@gpu-box", "connected": true],
            ["name": "cloud-1", "url": "wss://cloud-1.cmux.dev/acp?token=secret", "connected": true],
        ]])
        let peers = try #require((reply["result"] as? [String: Any])?["peers"] as? [[String: String]])
        #expect(peers == [
            ["name": "gpu-box", "transport": "ssh"],
            ["name": "cloud-1", "transport": "wss"],
        ])
    }

    @Test func anUnknownSchemeOrAMissingURLLeavesOnlyTheName() throws {
        let reply = try Self.reply(["peers": [
            ["name": "odd", "url": "file:///etc/passwd"],
            ["name": "bare"],
        ]])
        let peers = try #require((reply["result"] as? [String: Any])?["peers"] as? [[String: String]])
        #expect(peers == [["name": "odd"], ["name": "bare"]])
    }
}
