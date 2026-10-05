import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The relay's product rules (ad349 spec) and session scope (b):
/// 1. session/new (adopt too) without a cwd gets the pane's canonical workspace root; no root
///    refuses it with transport.path_invalid.
/// 2. The new tab page's project scan and open folders are roots only when the user picked one
///    by a gesture; once picked, the folder is a root.
/// 3. A typed folder outside every root is refused, and after a real gesture the host offers one
///    native sheet to add it as a root; Add makes it a root, Cancel leaves it refused.
/// (b) kill, permission_respond and permission_group_respond only for sessions this pane started
///    or shows.
@MainActor
@Suite(.serialized) struct AgentPaneProductRulesTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    final class Rig {
        let server = AcpmuxStandInServer()
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        var connection = 0
        var nextID = 10
        var sheets: [String] = []
        var answers: [@MainActor (Bool) -> Void] = []
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rules-\(UUID().uuidString)")
        lazy var root = folder("workspace")
        lazy var scanned = folder("scanned")
        lazy var typed = folder("typed")

        func folder(_ name: String) -> String {
            let url = base.appendingPathComponent(name)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return AcpmuxPathPolicy.canonical(url.path)!
        }

        func start() async throws {
            try await server.start()
            transport.deliver = { [unowned self] event, done in self.events.append(event); done() }
            transport.requestRoot = { [unowned self] folder, answer in self.sheets.append(folder); self.answers.append(answer) }
            connection = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
            _ = await transport.send(connection: connection, frames: [AgentPaneProductRulesTests.initialize])
        }

        /// Sends one request; returns its id.
        @discardableResult
        func send(_ method: String, _ params: [String: Any], expect: AgentPaneTransportError? = nil) async -> Int {
            nextID += 1
            let object: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
            let text = String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]), as: UTF8.self)
            let error = await transport.send(connection: connection, frames: [text])
            #expect(error == expect, "\(method) \(params)")
            // The daemon sees relay-owned ids: a counter per connection, 1 for the initialize, then
            // one more for each request the relay forwards.
            if error == nil {
                forwarded += 1
                relayIDs[nextID] = forwarded
            }
            return nextID
        }

        var forwarded = 1
        var relayIDs: [Int: Int] = [:]

        /// The daemon's copy of request `id`, when it got one (matched parsed: the relay re-encodes a
        /// checked frame, so its key order is not the page's).
        func received(_ pageID: Int) async -> [String: Any]? {
            guard let id = relayIDs[pageID] else { return nil }
            let find = { @Sendable (peers: [AcpmuxStandInServer.Peer]) -> [String: Any]? in
                for text in peers.first?.frames ?? [] {
                    if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                       (object["id"] as? NSNumber)?.intValue == id { return object }
                }
                return nil
            }
            _ = await server.wait(seconds: 2) { find($0) != nil }
            return find(server.peers)
        }

        func cwd(_ id: Int) async -> String? {
            ((await received(id))?["params"] as? [String: Any])?["cwd"] as? String
        }
    }

    @Test func aSessionWithoutACwdGetsThePaneRoot() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        let plain = await rig.send("session/new", ["mcpServers": [Any]()])
        #expect(await rig.cwd(plain) == root)
        let adopt = await rig.send("session/new", ["mcpServers": [Any](), "_meta": ["acpmux": ["adopt": ["harness": "claude", "agentSessionId": "a"]]]])
        #expect(await rig.cwd(adopt) == root)
        // No root: refused, never the daemon's cwd.
        rig.transport.primaryRoot = { nil }
        let none = await rig.send("session/new", ["mcpServers": [Any]()], expect: .pathInvalid)
        #expect(await rig.received(none) == nil)
    }

    @Test func aScannedFolderIsARootOnlyWhenTheUserPickedIt() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let scanned = rig.scanned
        rig.transport.gestureRoots = { [scanned] }
        rig.transport.primaryRoot = { scanned }
        // A page or script supplies it: refused.
        let supplied = await rig.send("session/new", ["cwd": scanned, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        #expect(await rig.received(supplied) == nil)
        // The user picked it (a gesture): it passes and is a root from then on.
        rig.transport.gestures.record()
        let picked = await rig.send("session/new", ["cwd": scanned, "mcpServers": [Any]()])
        #expect(await rig.cwd(picked) == scanned)
        let again = await rig.send("_acpmux/prewarm", ["harness": "claude", "cwd": scanned])
        #expect(await rig.cwd(again) == scanned)
    }

    @Test func aTypedFolderOutsideEveryRootOffersOneSheetAfterAGesture() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root, typed = rig.typed
        rig.transport.roots = { [root] }
        // No gesture: refused, no sheet.
        await rig.send("session/new", ["cwd": typed, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        #expect(rig.sheets.isEmpty)
        // After a gesture: refused, and one sheet; the refusal says a root was requested.
        rig.transport.gestures.record()
        let asked = await rig.send("session/new", ["cwd": typed, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        #expect(rig.sheets == [typed])
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !rig.events.flatMap(\.frames).contains(where: { $0.contains(#""id":\#(asked)"#) }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(rig.events.flatMap(\.frames).contains { $0.contains(#""id":\#(asked)"#) && $0.contains("rootRequested") })
        // One sheet at a time.
        rig.transport.gestures.record()
        await rig.send("session/new", ["cwd": typed, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        #expect(rig.sheets.count == 1)
        _ = rig.transport.gestures.consume()
        // Cancel: still refused.
        try #require(!rig.answers.isEmpty, "no sheet was offered")
        rig.answers.removeFirst()(false)
        await rig.send("session/new", ["cwd": typed, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        // Add: a root from then on.
        rig.transport.gestures.record()
        await rig.send("session/new", ["cwd": typed, "mcpServers": [Any]()], expect: .pathOutsideRoots)
        #expect(rig.sheets.count == 2)
        try #require(!rig.answers.isEmpty, "no sheet was offered")
        rig.answers.removeFirst()(true)
        let added = await rig.send("session/new", ["cwd": typed, "mcpServers": [Any]()])
        #expect(await rig.cwd(added) == typed)
    }

    @Test func killAndPermissionAnswersOnlyForThePanesSessions() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        await rig.send("_acpmux/kill", ["sessionId": "s-other", "purge": true], expect: .sessionNotInPane)
        await rig.send("_acpmux/permission_group_respond", ["sessionId": "s-other", "groupId": "g", "revision": 1, "decision": "deny"],
                       expect: .sessionNotInPane)
        await rig.send("_acpmux/permission_respond", ["sessionId": "s-other", "permissionId": "p", "optionId": "o"],
                       expect: .sessionNotInPane)
        // A session this pane started (the daemon's reply names it).
        let started = await rig.send("session/new", ["mcpServers": [Any]()])
        _ = await rig.received(started)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !rig.transport.sessions.contains("s-new") { try await Task.sleep(for: .milliseconds(5)) }
        await rig.send("_acpmux/kill", ["sessionId": "s-new", "purge": true])
        // Flag 3: an attach alone does not bring a session in. Attach a foreign session, then kill it.
        await rig.send("_acpmux/attach", ["sessionId": "s-foreign", "limit": 10])
        await rig.send("_acpmux/kill", ["sessionId": "s-foreign", "purge": true], expect: .sessionNotInPane)
        // A session the user opened in this pane (a click in the session list: an attach with a gesture).
        rig.transport.gestures.record()
        await rig.send("_acpmux/attach", ["sessionId": "s-shown", "limit": 10])
        await rig.send("_acpmux/permission_group_respond", ["sessionId": "s-shown", "groupId": "g", "revision": 1, "decision": "deny"])
        // A session the host persisted for the tab.
        rig.transport.sessions.add("s-tab")
        await rig.send("_acpmux/kill", ["sessionId": "s-tab", "purge": true])
    }
}
