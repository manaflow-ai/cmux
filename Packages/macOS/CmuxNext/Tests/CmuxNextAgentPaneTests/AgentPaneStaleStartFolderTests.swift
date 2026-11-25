import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A Codex chat after a reboot (Leo's NIGHTLY, 2026-11-25: "Couldn't start Codex: The app refused
/// this request. ... (code transport.path_invalid)"): a reboot wipes temporary folders and a
/// removed worktree stays gone, while a restored pane still hands the page that folder. The relay
/// refused the whole `session/new` with the generic refusal. Now a folder the host itself handed
/// the page re-resolves (the workspace root, else agent-home), an extra folder that is gone is
/// dropped, and only a folder the person named that is gone is refused, naming it.
@Suite(.serialized)
@MainActor
struct AgentPaneStaleStartFolderTests {
    static func frame(_ params: [String: Any]) throws -> String {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": 9, "method": "session/new", "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    static func params(_ text: String) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["params"] as? [String: Any]
    }

    static func folder(_ name: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("\(name)-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return try #require(AcpmuxPathPolicy.canonical(folder))
    }

    /// A folder that existed before the "reboot" and is gone after it.
    static func wiped(_ name: String) throws -> String {
        let folder = try folder(name)
        try FileManager.default.removeItem(atPath: folder)
        return folder
    }

    /// The post-reboot case: the pane's handshake folder (a temporary folder) was wiped and the
    /// workspace has no other: the start goes to agent-home, made now.
    @Test func aWipedInheritedFolderStartsInAgentHome() throws {
        let stale = try Self.wiped("tmp-before-reboot")
        let base = try Self.folder("agent-home")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let fill = AgentHomeFill(home: AgentHome(base: base), workspace: "w")
        let scope = AcpmuxPathPolicy.Scope(roots: [stale], fillCwd: stale, agentHome: fill, inheritedCwds: [stale])
        let text = try Self.frame(["cwd": stale, "mcpServers": [Any](), "_meta": ["acpmux": ["harness": "codex"]]])
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(text, scope: scope) else {
            Issue.record("a start whose inherited folder was wiped was refused")
            return
        }
        let cwd = try #require(Self.params(checked.text)?["cwd"] as? String)
        #expect(cwd == fill.home.path(for: "w"))
        #expect(AcpmuxPathPolicy.isDirectory(cwd))
    }

    /// The inherited folder is gone but the workspace still has a real root: the start goes there.
    @Test func aWipedInheritedFolderStartsInTheWorkspaceRoot() throws {
        let stale = try Self.wiped("worktree-removed")
        let root = try Self.folder("workspace-root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let scope = AcpmuxPathPolicy.Scope(roots: [root, stale], fillCwd: root, inheritedCwds: [stale])
        let text = try Self.frame(["cwd": stale, "mcpServers": [Any]()])
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(text, scope: scope) else {
            Issue.record("a start whose inherited folder was removed was refused")
            return
        }
        #expect(Self.params(checked.text)?["cwd"] as? String == root)
    }

    /// No cwd, and the workspace root the host would fill is itself gone: agent-home, not a refusal.
    @Test func aWipedWorkspaceRootFillsAgentHome() throws {
        let stale = try Self.wiped("root-before-reboot")
        let base = try Self.folder("agent-home")
        defer { try? FileManager.default.removeItem(atPath: base) }
        let fill = AgentHomeFill(home: AgentHome(base: base), workspace: "w")
        let scope = AcpmuxPathPolicy.Scope(roots: [stale], fillCwd: stale, agentHome: fill)
        let text = try Self.frame(["mcpServers": [Any]()])
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(text, scope: scope) else {
            Issue.record("a start with a wiped workspace root was refused")
            return
        }
        #expect(Self.params(checked.text)?["cwd"] as? String == fill.home.path(for: "w"))
    }

    /// An extra folder that is gone is dropped; the start goes on in its own folder with the rest.
    @Test func aWipedExtraFolderIsDropped() throws {
        let root = try Self.folder("extra-root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let kept = root + "/notes"
        try FileManager.default.createDirectory(atPath: kept, withIntermediateDirectories: true)
        let stale = try Self.wiped("extra-gone")
        let scope = AcpmuxPathPolicy.Scope(roots: [root], fillCwd: root)
        let one = try Self.frame(["cwd": root, "mcpServers": [Any](), "additionalDirectories": [stale, kept]])
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(one, scope: scope) else {
            Issue.record("a start with a wiped extra folder was refused")
            return
        }
        #expect(Self.params(checked.text)?["additionalDirectories"] as? [String] == [kept])
        let only = try Self.frame(["cwd": root, "mcpServers": [Any](), "additionalDirectories": [stale]])
        guard case .success(let bare) = AcpmuxPathPolicy.checkNow(only, scope: scope) else {
            Issue.record("a start whose only extra folder was wiped was refused")
            return
        }
        #expect(Self.params(bare.text)?["additionalDirectories"] == nil)
    }

    /// A folder the person named (not one the host handed the page) that is gone is refused,
    /// naming it, so the page says "The folder X no longer exists. Pick another folder."
    @Test func aPickedFolderThatIsGoneIsRefusedByName() throws {
        let root = try Self.folder("root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let picked = try Self.wiped("picked-gone")
        let scope = AcpmuxPathPolicy.Scope(roots: [root], fillCwd: root, inheritedCwds: [root])
        let text = try Self.frame(["cwd": picked, "mcpServers": [Any]()])
        guard case .failure(let refusal) = AcpmuxPathPolicy.checkNow(text, scope: scope) else {
            Issue.record("a picked folder that is gone started a chat elsewhere")
            return
        }
        #expect(refusal.error == .pathInvalid)
        #expect(refusal.reason == AcpmuxPathPolicy.missingReason)
        #expect(refusal.missingPath == picked)
        #expect(refusal.method == "session/new")
    }

    /// The native reply for a pick that is gone names the folder and says what to do.
    @Test func theFolderMissingReplyNamesTheFolder() throws {
        let reply = AgentPaneModel.folderMissing("/tmp/gone")
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? String == "transport.path_invalid")
        #expect((error["userMessage"] as? String)?.contains("/tmp/gone") == true)
        let details = try #require(error["details"] as? [String: Any])
        #expect(details["reason"] as? String == AcpmuxPathPolicy.missingReason)
        #expect(details["path"] as? String == "/tmp/gone")
    }
}
