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

    static func browse(_ params: [String: Any]) throws -> String {
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "_acpmux/browse", "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    /// Another machine's folder is that machine's to check (its acpmux holds it to its roots): a
    /// path only it has goes as named, never read from this Mac's disk; only its shape is checked.
    @Test func aPeersFolderGoesAsNamedAndOnlyItsShapeIsChecked() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let scope = AcpmuxPathPolicy.Scope(roots: [root], fillCwd: root, workspaceID: "0f8a2c1e-5b3d-4e6f-9a7b-1c2d3e4f5a6b")
        for path in ["/home/devbox/projects/api-\(UUID().uuidString)", "/tmp"] {
            guard case .success(let checked) = AcpmuxPathPolicy.checkNow(try Self.browse(["peer": "devbox", "path": path]), scope: scope) else {
                Issue.record("the relay refused a peer's folder: \(path)")
                continue
            }
            let params = try #require((try JSONSerialization.jsonObject(with: Data(checked.text.utf8)) as? [String: Any])?["params"] as? [String: Any])
            #expect(params["path"] as? String == path)
        }
        for bad in ["relative/x", "/a\u{0}b", "/" + String(repeating: "x", count: AcpmuxPathPolicy.peerFolderMaxBytes + 1)] {
            guard case .failure(let refusal) = AcpmuxPathPolicy.checkNow(try Self.browse(["peer": "devbox", "path": bad]), scope: scope) else {
                Issue.record("the relay sent a malformed peer folder: \(bad.prefix(40))")
                continue
            }
            #expect(refusal.error == .pathInvalid)
        }
        // This Mac's own folders stay held to the pane's roots.
        guard case .failure = AcpmuxPathPolicy.checkNow(try Self.browse(["path": "/home/devbox/missing-\(UUID().uuidString)"]), scope: scope) else {
            Issue.record("a local browse outside the roots went out")
            return
        }
    }

    /// A refusal and a machine that is down read apart through the relay: a listed reason stays,
    /// anything else in the error's data is dropped.
    @Test func anErrorKeepsOnlyAListedReason() throws {
        let shape = try #require(AcpmuxPaneMethods.replyShapes["_acpmux/browse"])
        func error(_ reason: String) throws -> [String: Any] {
            let reply: [String: Any] = ["jsonrpc": "2.0", "id": 9, "error": ["code": -32602, "message": "no", "data": ["reason": reason, "roots": ["/srv"]]]]
            let text = AcpmuxPaneMethods.filteredReply(reply, shape: shape, pageID: "4")
            return try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["error"] as? [String: Any])
        }
        for reason in ["browse.outside_roots", "peer_unreachable"] {
            #expect((try error(reason)["data"] as? [String: Any]).map { $0.keys.sorted() } == ["reason"])
            #expect((try error(reason)["data"] as? [String: Any])?["reason"] as? String == reason)
        }
        #expect(try error("something.else")["data"] == nil)
    }
}
