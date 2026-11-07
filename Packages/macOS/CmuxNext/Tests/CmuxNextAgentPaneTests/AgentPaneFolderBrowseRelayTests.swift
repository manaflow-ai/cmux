import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The composer's folder browser (webviews folderBrowse.ts; acpmux `_acpmux/browse`, hq#7442 row 4)
/// reads one folder of this Mac or a peer through the relay: its own params only, and a reply cut
/// to names, kinds and paths.
@Suite
struct AgentPaneFolderBrowseRelayTests {
    static func frame(_ params: String) -> String {
        #"{"jsonrpc":"2.0","id":1,"method":"_acpmux/browse","params":\#(params)}"#
    }

    @Test func thePaneMayBrowseAFolderWithItsOwnParamsOnly() throws {
        let asked = Self.frame(#"{"peer":"huge-blue","path":"/home/leo","dirsOnly":true,"offset":0,"limit":200}"#)
        guard case .send = AcpmuxPaneMethods.decide(asked, isFirst: false, localAppToken: nil) else {
            Issue.record("the relay refused the pane's _acpmux/browse")
            return
        }
        let object = try #require((try? JSONSerialization.jsonObject(with: Data(asked.utf8))) as? [String: Any])
        #expect(!AcpmuxPaneMethods.breaksParamsRule(object, modeFields: []))
        for extra in [#""sessionId":"s""#, #""cwd":"/""#, #""contents":true"#] {
            let invalid = Self.frame(#"{"path":"/home/leo",\#(extra)}"#)
            let invalidObject = try #require((try? JSONSerialization.jsonObject(with: Data(invalid.utf8))) as? [String: Any])
            #expect(AcpmuxPaneMethods.breaksParamsRule(invalidObject, modeFields: []), "\(extra)")
        }
    }

    @Test func theReplyKeepsOnlyNamesKindsAndPaths() throws {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/browse"])
        let reply: [String: Any] = [
            "path": "/home/leo", "parent": NSNull(), "home": "/home/leo", "total": 1, "offset": 0,
            "entries": [["name": "cmux", "path": "/home/leo/cmux", "kind": "dir", "text": "file body", "mode": 0o755]],
            "truncated": ["reason": "cap", "scanned": 5000, "extra": "x"],
            "token": "secret",
        ]
        let kept = try #require(AcpmuxPaneMethods.filtered(reply, to: shape) as? [String: Any])
        #expect(kept["token"] == nil)
        #expect(kept["parent"] == nil)
        let entry = try #require((kept["entries"] as? [[String: Any]])?.first)
        #expect(Set(entry.keys) == ["name", "path", "kind"])
        #expect((kept["truncated"] as? [String: Any])?.keys.sorted() == ["reason", "scanned"])
    }
}
