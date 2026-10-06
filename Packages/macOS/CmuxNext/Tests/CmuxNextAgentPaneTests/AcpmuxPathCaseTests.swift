import Foundation
import Testing
@testable import CmuxNextAgentPane

/// (c), ad349: APFS is case-insensitive and normalization-insensitive, and realpath keeps the
/// typed spelling. The relay canonicalizes to the filesystem's own spelling (then NFC), so a
/// case- or normalization-different path inside a root is accepted and sent as stored, and one
/// outside is still refused.
@Suite struct AcpmuxPathCaseTests {
    private func tree() throws -> (root: String, outside: String, caseInsensitive: Bool) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("path-case-\(UUID().uuidString)")
        let root = base.appendingPathComponent("Project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Inside"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("caf\u{e9}"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Elsewhere"), withIntermediateDirectories: true)
        let insensitive = FileManager.default.fileExists(atPath: base.appendingPathComponent("PROJECT").path)
        return (AcpmuxPathPolicy.canonical(root.path)!, AcpmuxPathPolicy.canonical(base.appendingPathComponent("Elsewhere").path)!, insensitive)
    }

    private func newSession(cwd: String) -> String {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": 4, "method": "session/new", "params": ["cwd": cwd, "mcpServers": [Any]()]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    private func cwd(_ result: Result<String, AcpmuxPathPolicy.Refusal>) -> String? {
        guard case .success(let text) = result,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return (object["params"] as? [String: Any])?["cwd"] as? String
    }

    @Test func aCaseDifferentPathInsideARootIsAcceptedInTheStoredSpelling() throws {
        let t = try tree()
        try #require(t.caseInsensitive, "this volume is case-sensitive; nothing to test")
        let typed = t.root.replacingOccurrences(of: "/Project", with: "/PROJECT") + "/inside"
        #expect(cwd(AcpmuxPathPolicy.checkNow(newSession(cwd: typed), roots: [t.root])) == t.root + "/Inside")
        // A root named in another case matches the same folder.
        let lowerRoot = t.root.replacingOccurrences(of: "/Project", with: "/project")
        #expect(cwd(AcpmuxPathPolicy.checkNow(newSession(cwd: t.root + "/Inside"), roots: [lowerRoot])) == t.root + "/Inside")
        #expect(AcpmuxPathPolicy.canonical(typed) == t.root + "/Inside")
    }

    @Test func aDecomposedNameIsTheSameFolder() throws {
        let t = try tree()
        let decomposed = t.root + "/cafe\u{301}"
        #expect(cwd(AcpmuxPathPolicy.checkNow(newSession(cwd: decomposed), roots: [t.root])) == t.root + "/caf\u{e9}")
    }

    @Test func aCaseDifferentPathOutsideIsRefused() throws {
        let t = try tree()
        let typed = t.outside.replacingOccurrences(of: "/Elsewhere", with: "/ELSEWHERE")
        #expect(AcpmuxPathPolicy.checkNow(newSession(cwd: typed), roots: [t.root])
            == .failure(.init(error: .pathOutsideRoots, requestID: "4", method: "session/new")))
    }
}
