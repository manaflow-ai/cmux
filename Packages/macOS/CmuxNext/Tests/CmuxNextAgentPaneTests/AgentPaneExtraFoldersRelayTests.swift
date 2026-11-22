import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat's extra folders (the composer's Add folder…, webviews extraFolders.ts) go in its
/// `session/new` as `additionalDirectories` (acpmux, cmux#32811). The params rule refused every
/// `session/new` that named them, so no folder reached acpmux. On this Mac each one is checked
/// as `cwd` is (canonical, inside the pane's roots); on another machine only its shape is, as that
/// machine's `cwd` is, and its acpmux checks it.
@Suite(.serialized)
@MainActor
struct AgentPaneExtraFoldersRelayTests {
    static func frame(_ params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": 9, "method": "session/new", "params": params]
    }

    static func text(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    static func params(_ text: String) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["params"] as? [String: Any]
    }

    static func macFolder(_ name: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("\(name)-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return try #require(AcpmuxPathPolicy.canonical(folder))
    }

    @Test func theParamsRuleTakesExtraFolders() {
        let object = Self.frame(["cwd": "/a", "mcpServers": [Any](), "additionalDirectories": ["/b"],
                                 "_meta": ["acpmux": ["harness": "claude"]]])
        #expect(!AcpmuxPaneMethods.breaksParamsRule(object, modeFields: []))
    }

    @Test func thisMacsFoldersAreCheckedAsTheChatsFolder() throws {
        let root = try Self.macFolder("extra-root")
        let outside = try Self.macFolder("extra-outside")
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        let notes = root + "/notes"
        try FileManager.default.createDirectory(atPath: notes, withIntermediateDirectories: true)
        let scope = AcpmuxPathPolicy.Scope(roots: [root], fillCwd: root)
        let inside = try Self.text(Self.frame(["cwd": root, "mcpServers": [Any](), "additionalDirectories": [notes + "/"]]))
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(inside, scope: scope) else {
            Issue.record("a folder inside the pane's roots was refused")
            return
        }
        #expect(Self.params(checked.text)?["additionalDirectories"] as? [String] == [notes])
        let far = try Self.text(Self.frame(["cwd": root, "mcpServers": [Any](), "additionalDirectories": [outside]]))
        guard case .failure(let refusal) = AcpmuxPathPolicy.checkNow(far, scope: scope) else {
            Issue.record("a folder outside the pane's roots passed")
            return
        }
        #expect(refusal.error == .pathOutsideRoots)
    }

    @Test func anotherMachinesFoldersGoAsNamed() throws {
        let root = try Self.macFolder("extra-peer-root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let scope = AcpmuxPathPolicy.Scope(roots: [root], fillCwd: root)
        let folders = ["/home/devbox/datasets-\(UUID().uuidString)", "/srv/a b/ü"]
        let meta: [String: Any] = ["acpmux": ["harness": "claude", "peer": "devbox"]]
        for cwd in ["/home/devbox/model", nil] as [String?] {
            var params: [String: Any] = ["mcpServers": [Any](), "additionalDirectories": folders, "_meta": meta]
            if let cwd { params["cwd"] = cwd }
            guard case .success(let checked) = AcpmuxPathPolicy.checkNow(try Self.text(Self.frame(params)), scope: scope) else {
                Issue.record("a start on another machine with its folders was refused")
                continue
            }
            let sent = try #require(Self.params(checked.text))
            #expect(sent["additionalDirectories"] as? [String] == folders)
            #expect(sent["cwd"] as? String == cwd)
            #expect(checked.gestureRootsUsed.isEmpty)
        }
        // Not a path: refused here.
        let bad = try Self.text(Self.frame(["cwd": "/home/devbox/model", "mcpServers": [Any](),
                                            "additionalDirectories": ["relative"], "_meta": meta]))
        guard case .failure(let refusal) = AcpmuxPathPolicy.checkNow(bad, scope: scope) else {
            Issue.record("a relative folder for another machine passed")
            return
        }
        #expect(refusal.error == .pathInvalid)
    }

    /// cmux#34407: two typed folders outside the pane's roots. The Send's gesture granted only the
    /// first and checked once, so the second refused the start.
    @Test func oneSendGrantsEveryTypedFolder() async throws {
        let root = try Self.macFolder("extra-grant-root")
        let first = try Self.macFolder("extra-grant-a")
        let second = try Self.macFolder("extra-grant-b")
        defer { for folder in [root, first, second] { try? FileManager.default.removeItem(atPath: folder) } }
        var scope = AcpmuxPathPolicy.Scope(roots: [root], fillCwd: root)
        let text = try Self.text(Self.frame(["cwd": root, "mcpServers": [Any](), "additionalDirectories": [first, second]]))
        let check = { AcpmuxPathPolicy.checkNow(text, scope: scope).map(\.gestureRootsUsed) }
        var granted: [String] = []
        let result = await AgentPaneTransport.grantTypedFolders(check(), grant: { folder in
            granted.append(folder)
            scope.granted.append(folder)
        }, recheck: { check() })
        guard case .success = result else {
            Issue.record("the second typed folder still refused the start: \(String(describing: result))")
            return
        }
        #expect(granted == [first, second])
    }

    /// A folder whose grant does not let the frame pass is tried once, not again and again.
    @Test func aFolderThatStaysRefusedEndsTheGrants() async {
        let refusal = AcpmuxPathPolicy.Refusal(error: .pathOutsideRoots, requestID: nil, method: "session/new",
                                               outsidePath: "/elsewhere")
        var grants = 0
        let result = await AgentPaneTransport.grantTypedFolders(.failure(refusal), grant: { _ in grants += 1 },
                                                                recheck: { .failure(refusal) })
        #expect(grants == 1)
        guard case .failure(let left) = result else {
            Issue.record("a folder that stays refused passed")
            return
        }
        #expect(left.error == .pathOutsideRoots)
    }
}
