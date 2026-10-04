import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Every `cwd` and `path` the page sends is limited to the pane's workspace roots: made canonical
/// first, then compared by path components (origin lead rule).
@Suite struct AcpmuxPathPolicyTests {
    /// A temporary tree: `root/inside`, `outside`, `root2`, and `root/escape` -> `outside`.
    private func tree() throws -> (root: String, outside: String, sibling: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("path-policy-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        let sibling = base.appendingPathComponent("root2")
        for url in [root.appendingPathComponent("inside"), outside, sibling] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        // /var/folders is /private/var/folders: the canonical forms.
        return (AcpmuxPathPolicy.canonical(root.path)!, AcpmuxPathPolicy.canonical(outside.path)!, AcpmuxPathPolicy.canonical(sibling.path)!)
    }

    private func newSession(cwd: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 4, "method": "session/new", "params": ["cwd": cwd, "mcpServers": []]])
        return String(decoding: data, as: UTF8.self)
    }

    private func cwd(of result: Result<String, AcpmuxPathPolicy.Refusal>) -> String? {
        guard case .success(let text) = result,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return (object["params"] as? [String: Any])?["cwd"] as? String
    }

    @Test func aCwdInsideARootIsSentCanonical() throws {
        let t = try tree()
        #expect(cwd(of: AcpmuxPathPolicy.checkNow(newSession(cwd: t.root + "/inside"), roots: [t.root])) == t.root + "/inside")
        #expect(cwd(of: AcpmuxPathPolicy.checkNow(newSession(cwd: t.root), roots: [t.root])) == t.root)
        // A root named through a symlinked path (/var -> /private/var) still matches.
        let viaVar = t.root.replacingOccurrences(of: "/private/var/", with: "/var/")
        #expect(cwd(of: AcpmuxPathPolicy.checkNow(newSession(cwd: viaVar + "/inside"), roots: [viaVar])) == t.root + "/inside")
    }

    @Test func aCwdOutsideTheRootsIsRefused() throws {
        let t = try tree()
        #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: t.outside), roots: [t.root])
            == .failure(.init(error: .pathOutsideRoots, requestID: "4", method: "session/new")))
        // A string prefix is not a component prefix: root2 is not under root.
        #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: t.sibling), roots: [t.root])
            == .failure(.init(error: .pathOutsideRoots, requestID: "4", method: "session/new")))
        // No roots: every path is refused.
        #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: t.root), roots: [])
            == .failure(.init(error: .pathOutsideRoots, requestID: "4", method: "session/new")))
        // The filesystem root is never a workspace root.
        #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: t.outside), roots: ["/"])
            == .failure(.init(error: .pathOutsideRoots, requestID: "4", method: "session/new")))
    }

    @Test func aSymlinkInsideARootThatPointsOutsideIsRefused() throws {
        let t = try tree()
        #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: t.root + "/escape"), roots: [t.root])
            == .failure(.init(error: .pathOutsideRoots, requestID: "4", method: "session/new")))
    }

    @Test func dotDotOutOfARootIsRefused() throws {
        let t = try tree()
        let name = (t.outside as NSString).lastPathComponent
        #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: t.root + "/inside/../../" + name), roots: [t.root])
            == .failure(.init(error: .pathOutsideRoots, requestID: "4", method: "session/new")))
        // `..` that stays inside is made canonical.
        #expect(cwd(of: AcpmuxPathPolicy.checkNow(newSession(cwd: t.root + "/inside/.."), roots: [t.root])) == t.root)
    }

    @Test func aRelativeMissingOrNonDirectoryCwdIsInvalid() throws {
        let t = try tree()
        let file = t.root + "/inside/file"
        FileManager.default.createFile(atPath: file, contents: Data())
        for path in ["inside", t.root + "/missing", file] {
            #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: path), roots: [t.root])
                == .failure(.init(error: .pathInvalid, requestID: "4", method: "session/new")), "\(path)")
        }
    }

    @Test func framesWithoutAPathPassUnchanged() {
        let text = #"{"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"s"}}"#
        #expect(AcpmuxPathPolicy.checkNow(text, roots: []) == .success(text))
    }
}
