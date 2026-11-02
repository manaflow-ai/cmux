import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A new chat on another machine (an ssh peer, `_meta.acpmux.peer`) starts in a folder of that
/// machine: the composer's project picker and the New Tab's location row name one (webviews App.tsx
/// `chooseProject`, newtab `pickMachine`). The relay's folder rule read every `session/new`'s `cwd`
/// from this Mac's disk, so a folder only that machine has was refused (`transport.path_invalid`)
/// before acpmux saw the start, a click or not; and a folder of the same name on this Mac was made
/// canonical here and, on a click, added as a root of this Mac's pane. Now only the folder's shape
/// is checked here, it goes as the page named it, and the peer's acpmux checks it.
@Suite(.serialized)
@MainActor
struct AgentPanePeerStartFolderTests {
    /// A folder no Mac has (a Linux machine's project).
    static let peerOnly = "/home/devbox/projects/api-\(UUID().uuidString)"

    static func start(id: Int = 7, cwd: Any? = nil, peer: String? = "devbox", extra: [String: Any] = [:]) throws -> String {
        var acpmux: [String: Any] = ["harness": "claude"]
        if let peer { acpmux["peer"] = peer }
        var params: [String: Any] = ["mcpServers": [], "_meta": ["acpmux": acpmux]]
        if let cwd { params["cwd"] = cwd }
        params.merge(extra) { $1 }
        let frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": "session/new", "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    static func params(_ text: String) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["params"] as? [String: Any]
    }

    /// A folder on this Mac, removed by the caller.
    static func macFolder(_ name: String) throws -> String {
        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("\(name)-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return try #require(AcpmuxPathPolicy.canonical(folder))
    }

    @Test func aFolderOnlyThePeerHasGoesAsNamed() throws {
        let root = try Self.macFolder("peer-start-root")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let scope = AcpmuxPathPolicy.Scope(roots: [root], fillCwd: root, workspaceID: "0f8a2c1e-5b3d-4e6f-9a7b-1c2d3e4f5a6b")
        // `/tmp` is a link on this Mac, and the peer's own `/tmp` is not this Mac's: no rewrite.
        for cwd in [Self.peerOnly, "/tmp", "/srv/a b/ü", "/" + String(repeating: "x", count: AcpmuxPathPolicy.peerFolderMaxBytes - 1)] {
            guard case .success(let checked) = AcpmuxPathPolicy.checkNow(try Self.start(cwd: cwd), scope: scope) else {
                Issue.record("the start on another machine was refused: \(cwd.prefix(60))")
                continue
            }
            let params = try #require(Self.params(checked.text))
            #expect(params["cwd"] as? String == cwd)
            #expect(checked.gestureRootsUsed.isEmpty)
            let acpmux = (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
            #expect(acpmux?["peer"] as? String == "devbox")
            #expect(acpmux?["workspaceId"] == nil, "a peer's workspaces are not this Mac's")
        }
        // The same folder for a chat on this Mac is still refused (not on this disk).
        for peer in [nil, ""] as [String?] {
            guard case .failure(let refusal) = AcpmuxPathPolicy.checkNow(try Self.start(cwd: Self.peerOnly, peer: peer), scope: scope) else {
                Issue.record("a local start in a folder this Mac lacks passed")
                continue
            }
            #expect(refusal.error == .pathInvalid)
        }
    }

    @Test func aFolderOfTheSameNameOnThisMacIsNotOffered() throws {
        let root = try Self.macFolder("peer-start-root")
        let outside = try Self.macFolder("peer-start-outside")
        defer {
            try? FileManager.default.removeItem(atPath: root)
            try? FileManager.default.removeItem(atPath: outside)
        }
        let scope = AcpmuxPathPolicy.Scope(roots: [root], gestureRoots: [outside])
        // A start on the peer: no refusal that would have a click add this Mac's folder as a root,
        // and no gesture root of this Mac's spent.
        guard case .success(let checked) = AcpmuxPathPolicy.checkNow(try Self.start(cwd: outside), scope: scope) else {
            Issue.record("the start on another machine was refused")
            return
        }
        #expect(checked.gestureRootsUsed.isEmpty)
        #expect(Self.params(checked.text)?["cwd"] as? String == outside)
        // On this Mac it stays a folder the person picks (a gesture root).
        guard case .success(let local) = AcpmuxPathPolicy.checkNow(try Self.start(cwd: outside, peer: nil), scope: scope) else {
            Issue.record("refused")
            return
        }
        #expect(local.gestureRootsUsed == [outside])
    }

    @Test func aPeerFolderMustBeOneAbsolutePath() throws {
        let scope = AcpmuxPathPolicy.Scope(roots: [])
        let refused: [Any] = ["", "relative/dir", "~/src", "./x", "/a\u{0}b",
                              "/" + String(repeating: "x", count: AcpmuxPathPolicy.peerFolderMaxBytes),
                              NSNull(), 1, true, ["/a"], ["path": "/a"]]
        for cwd in refused {
            guard case .failure(let refusal) = AcpmuxPathPolicy.checkNow(try Self.start(cwd: cwd), scope: scope) else {
                Issue.record("passed: \(String(describing: cwd).prefix(60))")
                continue
            }
            #expect(refusal.error == .pathInvalid)
            #expect(refusal.requestID == "7")
        }
        // Only the start's own folder is the peer's: a folder anywhere else in it is still this Mac's.
        let server: [String: Any] = ["name": "x", "command": "/bin/echo", "args": [], "env": [], "cwd": Self.peerOnly]
        guard case .failure(let nested) = AcpmuxPathPolicy.checkNow(try Self.start(cwd: Self.peerOnly, extra: ["mcpServers": [server]]),
                                                                    scope: scope) else {
            Issue.record("a nested folder skipped this Mac's check")
            return
        }
        #expect(nested.error == .pathInvalid)
    }

    @Test(.timeLimit(.minutes(1))) func theStartReachesAcpmuxWithThePeersFolder() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let root = try Self.macFolder("peer-start-pane")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.roots = { [root] }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)
        let starts = { server.peers.first?.frames.filter { $0.contains("session/new") } ?? [] }

        // A chat on this Mac in that folder is still refused, and never reaches acpmux.
        #expect(await transport.send(connection: id, frames: [try Self.start(id: 1, cwd: Self.peerOnly, peer: nil)]) == .pathInvalid)
        #expect(starts().isEmpty, "\(starts())")

        // The page's start on devbox, in devbox's folder: no click needed for the folder.
        let sent = await transport.send(connection: id, frames: [try Self.start(id: 2, cwd: Self.peerOnly)])
        #expect(sent == nil, "the relay refused the start on another machine in its own folder")
        guard sent == nil else { return }
        _ = await inbox.frame(containing: #""id":2"#)
        let params = try #require(starts().first.flatMap(Self.params))
        #expect(params["cwd"] as? String == Self.peerOnly)
        #expect(((params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["peer"] as? String == "devbox")
        #expect(transport.addedRoots.isEmpty, "a peer's folder became a root of this Mac's pane")

        // The person's click on a start in a folder of the same name on this Mac, outside its roots:
        // the start goes to devbox and the click adds no root of this Mac's pane.
        let outside = try Self.macFolder("peer-start-outside")
        defer { try? FileManager.default.removeItem(atPath: outside) }
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [try Self.start(id: 3, cwd: outside)]) == nil)
        _ = await inbox.frame(containing: #""id":3"#)
        #expect(starts().count == 2)
        #expect(transport.addedRoots.isEmpty, "the click made a peer's folder a root of this Mac's pane")
        // The same click on a start on this Mac still adds that folder (the person typed it).
        transport.gestures.record()
        #expect(await transport.send(connection: id, frames: [try Self.start(id: 4, cwd: outside, peer: nil)]) == nil)
        #expect(transport.addedRoots == [outside])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["workspace", "agent-home", "none"])
    func aPeerWithoutAFolderReachesAcpmuxWithoutALocalDefault(_ fallback: String) async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let root = try Self.macFolder("peer-default-pane")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = AgentHome(base: root + "/agent-home")
        let inbox = AgentPaneRelayedAllowTests.PageInbox()
        let transport = AgentPaneTransport()
        transport.deliver = { event, done in inbox.deliver(event.frames); done() }
        transport.roots = { fallback == "workspace" ? [root] : [] }
        transport.primaryRoot = { fallback == "workspace" ? root : nil }
        transport.agentHome = { fallback == "agent-home" ? AgentHomeFill(home: home, workspace: "peer-default") : nil }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        defer { transport.close(connection: id) }
        #expect(await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#]) == nil)

        let sent = await transport.send(connection: id, frames: [try Self.start(id: 1)])
        #expect(sent == nil, "a peer chooses its default folder without needing a local folder")
        guard sent == nil else { return }
        _ = await inbox.frame(containing: #""id":1"#)
        let forwarded = try #require(server.peers.first?.frames.first { $0.contains("session/new") })
        let params = try #require(Self.params(forwarded))
        #expect(params["cwd"] == nil, "the native transport must not send this Mac's folder to the peer")
        let acpmux = (params["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        #expect(acpmux?["peer"] as? String == "devbox")
        #expect(transport.addedRoots.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.path(for: "peer-default") ?? ""))
    }
}
