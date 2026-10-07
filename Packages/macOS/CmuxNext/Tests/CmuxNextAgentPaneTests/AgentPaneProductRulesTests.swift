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

    /// The page names its chat with the folder trust question (`acp.trust.get` / `acp.trust.set`
    /// carry `sessionId`, so acpmux asks the chat's own peer). The relay passes a session in the
    /// pane's scope, refuses any other with `sessionNotInPane`, and still passes a frame without
    /// one (a new chat before its session exists).
    @Test func theTrustQuestionNamesOnlyThePanesSession() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        await rig.send("acp.trust.get", ["cwd": root])
        let started = await rig.send("session/new", ["mcpServers": [Any]()])
        _ = await rig.received(started)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, !rig.transport.sessions.contains("s-new") { try await Task.sleep(for: .milliseconds(5)) }
        await rig.send("acp.trust.get", ["cwd": root, "sessionId": "s-new"])
        // Trust grants: it needs the click's gesture.
        rig.transport.gestures.record()
        await rig.send("acp.trust.set", ["cwd": root, "level": "trusted", "sessionId": "s-new"])
        await rig.send("acp.trust.get", ["cwd": root, "sessionId": "s-other"], expect: .sessionNotInPane)
        await rig.send("acp.trust.set", ["cwd": root, "level": "trusted", "sessionId": "s-other"], expect: .sessionNotInPane)
        await rig.send("acp.trust.get", ["cwd": root, "sessionId": 7], expect: .sessionNotInPane)
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

    /// An attach is not a grant: the click that opens a session in the pane (an attach with a
    /// gesture) is still there for the prompt the same click sends. Only the grant uses it.
    @Test func anAttachNeverSpendsTheGestureThatAPromptOnTheSameClickNeeds() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        rig.transport.gestures.record()
        await rig.send("_acpmux/attach", ["sessionId": "s-clicked", "limit": 10])
        #expect(rig.transport.sessions.contains("s-clicked"))
        #expect(rig.transport.gestures.isAvailable)
        await rig.send("session/prompt", ["sessionId": "s-clicked", "prompt": [Any]()])
        // The prompt used the click: the next grant needs a new one.
        await rig.send("session/prompt", ["sessionId": "s-clicked", "prompt": [Any]()], expect: .gestureRequired)
    }

    /// A click is two single-use credits: one scope-add (an attach of a session that is not yet
    /// the pane's) and one grant. A second attach on the same click brings nothing in.
    @Test func oneClickBringsOneSessionInNotTwo() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        rig.transport.gestures.record()
        await rig.send("_acpmux/attach", ["sessionId": "s-first", "limit": 10])
        await rig.send("_acpmux/attach", ["sessionId": "s-second", "limit": 10])
        #expect(rig.transport.sessions.contains("s-first"))
        #expect(!rig.transport.sessions.contains("s-second"))
        await rig.send("_acpmux/kill", ["sessionId": "s-second", "purge": true], expect: .sessionNotInPane)
        // The grant credit of the same click is still there.
        await rig.send("session/prompt", ["sessionId": "s-first", "prompt": [Any]()])
    }

    /// One click is one grant: a second prompt on it is refused.
    @Test func oneClickIsOneGrant() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        rig.transport.sessions.add("s-tab")
        rig.transport.gestures.record()
        await rig.send("session/prompt", ["sessionId": "s-tab", "prompt": [Any]()])
        await rig.send("session/prompt", ["sessionId": "s-tab", "prompt": [Any]()], expect: .gestureRequired)
    }

    /// A second attach on one click is a read-only view: the pane never sends anything to that
    /// session. Every write frame for it is refused (session_not_in_pane or gesture_required) and
    /// the daemon sees none of them; the same frames for the session in scope follow the normal rules.
    @Test func aReadOnlyViewNeverSendsAnythingToItsSession() async throws {
        let rig = Rig()
        try await rig.start()
        defer { rig.server.stop() }
        let root = rig.root
        rig.transport.roots = { [root] }
        rig.transport.primaryRoot = { root }
        rig.transport.gestures.record()
        await rig.send("_acpmux/attach", ["sessionId": "s-scope", "limit": 10])
        await rig.send("_acpmux/attach", ["sessionId": "s-view", "limit": 10])
        #expect(rig.transport.sessions.contains("s-scope"))
        #expect(!rig.transport.sessions.contains("s-view"))
        let writes: [(String, [String: Any])] = [
            ("session/prompt", ["prompt": [Any]()]),
            ("session/set_mode", ["modeId": "bypassPermissions"]),
            ("session/set_config_option", ["configId": "mode", "value": "bypassPermissions"]),
            ("session/set_model", ["modelId": "m"]),
            ("_acpmux/permission_respond", ["permissionId": "p", "optionId": "allow_once"]),
            ("_acpmux/permission_group_respond", ["groupId": "g", "revision": 1, "decisionKey": "k", "decision": "allow_once"]),
            ("_acpmux/permission_chat_revoke", [:]),
            ("_acpmux/kill", ["purge": true]),
        ]
        for (method, params) in writes {
            rig.nextID += 1
            var fields = params
            fields["sessionId"] = "s-view"
            let object: [String: Any] = ["jsonrpc": "2.0", "id": rig.nextID, "method": method, "params": fields]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let error = await rig.transport.send(connection: rig.connection, frames: [text])
            #expect(error == .sessionNotInPane || error == .gestureRequired, "\(method) for a read-only view: \(String(describing: error))")
        }
        // session/cancel is a notification: refused all the same.
        let cancel = #"{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s-view"}}"#
        #expect(await rig.transport.send(connection: rig.connection, frames: [cancel]) == .sessionNotInPane)
        // The session in scope: the click's grant credit is still there for one prompt.
        await rig.send("session/prompt", ["sessionId": "s-scope", "prompt": [Any]()])
        await rig.send("_acpmux/kill", ["sessionId": "s-scope", "purge": true])
        _ = await rig.server.wait(seconds: 2) { ($0.first?.frames ?? []).contains { $0.contains("\"_acpmux/kill\"") } }
        // The daemon saw only the attach for the read-only view.
        let toView = (rig.server.peers.first?.frames ?? []).filter { $0.contains("\"s-view\"") }
        #expect(toView.count == 1 && toView.first?.contains("_acpmux/attach") == true, "\(toView)")
    }
}
