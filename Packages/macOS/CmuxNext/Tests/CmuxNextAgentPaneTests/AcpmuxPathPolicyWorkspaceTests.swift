import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The pane host names a new local chat's workspace to acpmux (`_meta.acpmux.workspaceId` on
/// `session/new`), so a workspace's sub-session limit applies to chats started in the app. The
/// value is the host's (``AcpmuxPathPolicy/Scope/workspaceID``), never the page's.
struct AcpmuxPathPolicyWorkspaceTests {
    private static let workspace = "0F8A2C1E-5B3D-4E6F-9A7B-1C2D3E4F5A6B"

    /// A folder the scope roots, removed by the caller.
    private func root() throws -> String {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ws-stamp-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return try #require(AcpmuxPathPolicy.canonical(folder))
    }

    private func newSession(cwd: String, acpmux: [String: Any]? = nil) throws -> String {
        var params: [String: Any] = ["cwd": cwd, "mcpServers": []]
        if let acpmux { params["_meta"] = ["acpmux": acpmux] }
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": "session/new", "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    /// The checked frame's `_meta.acpmux`, nil when it has none.
    private func checkedAcpmux(_ text: String, scope: AcpmuxPathPolicy.Scope) throws -> [String: Any]? {
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(text, scope: scope) else {
            Issue.record("the frame was refused")
            return nil
        }
        let object = try #require(try JSONSerialization.jsonObject(with: Data(checked.text.utf8)) as? [String: Any])
        let params = try #require(object["params"] as? [String: Any])
        return (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
    }

    @Test func aLocalNewChatCarriesThePanesWorkspaceLowercased() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let scope = AcpmuxPathPolicy.Scope(roots: [folder], workspaceID: Self.workspace)
        let acpmux = try checkedAcpmux(try newSession(cwd: folder, acpmux: ["harness": "claude"]), scope: scope)
        #expect(acpmux?["workspaceId"] as? String == Self.workspace.lowercased())
        #expect(acpmux?["harness"] as? String == "claude", "the page's own keys stay")
        // A frame with no `_meta` gets one.
        let bare = try checkedAcpmux(try newSession(cwd: folder), scope: scope)
        #expect(bare?["workspaceId"] as? String == Self.workspace.lowercased())
    }

    @Test func thePageCannotNameAWorkspace() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let other = "11111111-2222-4333-8444-555555555555"
        let text = try newSession(cwd: folder, acpmux: ["workspaceId": other])
        // The params rule (P1) refuses the key from the page before any other rule runs.
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(AcpmuxPaneMethods.breaksParamsRule(object, modeFields: nil))
        // Past it, the host's value replaces the page's; with no workspace, the page's is dropped.
        let stamped = try checkedAcpmux(text, scope: AcpmuxPathPolicy.Scope(roots: [folder], workspaceID: Self.workspace))
        #expect(stamped?["workspaceId"] as? String == Self.workspace.lowercased())
        let dropped = try checkedAcpmux(text, scope: AcpmuxPathPolicy.Scope(roots: [folder]))
        #expect(dropped?["workspaceId"] == nil)
    }

    @Test func noWorkspaceNoStamp() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let text = try newSession(cwd: folder, acpmux: ["harness": "claude"])
        #expect(try checkedAcpmux(text, scope: AcpmuxPathPolicy.Scope(roots: [folder]))?["workspaceId"] == nil)
        // A key acpmux would refuse (a stand-in's `handle:` id, a non-UUID key) is not sent either.
        for key in ["handle:3", "", "0f8a2c1e5b3d4e6f9a7b1c2d3e4f5a6b", "0f8a2c1e-5b3d-4e6f-9a7b-1c2d3e4f5a6g",
                    "０f8a2c1e-5b3d-4e6f-9a7b-1c2d3e4f5a6b"] {
            let scope = AcpmuxPathPolicy.Scope(roots: [folder], workspaceID: key)
            #expect(try checkedAcpmux(text, scope: scope)?["workspaceId"] == nil, "\(key)")
        }
        // A frame with no `_meta` gets none.
        let plain = try newSession(cwd: folder)
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(plain, scope: AcpmuxPathPolicy.Scope(roots: [folder])) else {
            Issue.record("refused")
            return
        }
        #expect(!checked.text.contains("_meta"))
    }

    @Test func aStartOnAPeerAndOtherMethodsGetNoStamp() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let scope = AcpmuxPathPolicy.Scope(roots: [folder], workspaceID: Self.workspace)
        let peer = try checkedAcpmux(try newSession(cwd: folder, acpmux: ["peer": "big-box"]), scope: scope)
        #expect(peer?["workspaceId"] == nil)
        #expect(peer?["peer"] as? String == "big-box")
        // An empty peer is a local start, as acpmux reads it.
        let local = try checkedAcpmux(try newSession(cwd: folder, acpmux: ["peer": ""]), scope: scope)
        #expect(local?["workspaceId"] as? String == Self.workspace.lowercased())
        let harnesses = #"{"jsonrpc":"2.0","id":3,"method":"_acpmux/harnesses","params":{"cwd":"\#(folder)"}}"#
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(harnesses, scope: scope) else {
            Issue.record("refused")
            return
        }
        #expect(!checked.text.contains("workspaceId"))
    }
}
