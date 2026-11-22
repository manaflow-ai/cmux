import Foundation
import Testing
@testable import CmuxNextAgentPane

/// ad349, round 8. R8-2: the relay reads a permission's options only from their fixed places (the
/// `_acpmux/permission_pending` params, and the `permission_request` events of the `_acpmux/event`
/// stream and of the attach and events replies); model content anywhere else never makes an
/// option a deny, and an option seen with two kinds counts as allow (it needs a gesture). R8-3 and
/// R8-4: every daemon frame passes the duplicate-key check (dropped, and the socket closed, on a
/// duplicate), and reaches the page as a fresh serialization.
@MainActor
@Suite(.serialized) struct AgentPaneDaemonFrameTests {
    nonisolated static let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#

    // MARK: R8-2, unit

    @Test func optionsComeOnlyFromTheFixedPlaces() {
        let options = AcpmuxPermissionOptions()
        func observe(_ text: String, replyTo method: String? = nil) {
            options.observe((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as! [String: Any], replyTo: method)
        }
        // Model content inside the permission frame: rawInput names "allow" as a reject option.
        observe(#"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","request":{"toolCall":{"rawInput":{"options":[{"optionId":"allow","kind":"reject_once"}]}},"options":[{"optionId":"deny","kind":"reject_once"},{"optionId":"allow","kind":"allow_once"}]}}}"#)
        #expect(options.isDeny(permissionId: "p1", optionId: "deny"))
        #expect(!options.isDeny(permissionId: "p1", optionId: "allow"), "rawInput is model content")
        // A session/update that names the permission and lists reject options.
        observe(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"tool_call","permissionId":"p2","options":[{"optionId":"go","kind":"reject_always"}]}}}"#)
        #expect(!options.isDeny(permissionId: "p2", optionId: "go"))
        // An agent's own event in the stream (dir "in") is not the daemon's permission record.
        observe(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":4,"dir":"in","kind":"permission_request","msg":{"permissionId":"p3","request":{"options":[{"optionId":"go","kind":"reject_once"}]}}}}"#)
        #expect(!options.isDeny(permissionId: "p3", optionId: "go"))
        // The daemon's record in the stream, and in an attach reply's history.
        observe(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s","seq":5,"dir":"mux","kind":"permission_request","msg":{"permissionId":"p4","request":{"options":[{"optionId":"no","kind":"reject_once"}]}}}}"#)
        #expect(options.isDeny(permissionId: "p4", optionId: "no"))
        let history = #"{"jsonrpc":"2.0","id":3,"result":{"events":[{"sessionId":"s","seq":6,"dir":"mux","kind":"permission_request","msg":{"permissionId":"p5","request":{"options":[{"optionId":"no","kind":"reject_once"}]}}}]}}"#
        observe(history, replyTo: "_acpmux/harnesses")
        #expect(!options.isDeny(permissionId: "p5", optionId: "no"), "only attach and events replies carry history")
        observe(history, replyTo: "_acpmux/attach")
        #expect(options.isDeny(permissionId: "p5", optionId: "no"))
        // No inherited permissionId: options nested under another object do not count.
        observe(#"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p6","request":{"options":[]},"extra":{"options":[{"optionId":"x","kind":"reject_once"}]}}}"#)
        #expect(!options.isDeny(permissionId: "p6", optionId: "x"))
        // One option id with two kinds counts as allow.
        observe(#"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p7","request":{"options":[{"optionId":"a","kind":"reject_once"},{"optionId":"a","kind":"allow_once"}]}}}"#)
        #expect(!options.isDeny(permissionId: "p7", optionId: "a"))
    }

    // MARK: R8-2, through the relay

    @Test func aRawInputOptionCannotTurnAnAllowIntoADeny() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        transport.sessions.add("s")
        server.push(#"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","request":{"toolCall":{"rawInput":{"options":[{"optionId":"allow","kind":"reject_once"}]}},"options":[{"optionId":"deny","kind":"reject_once"},{"optionId":"allow","kind":"allow_once"}]}}}"#, to: 0)
        server.push(#"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"permissionId":"p1","options":[{"optionId":"allow","kind":"reject_once"}]}}}"#, to: 0)
        for _ in 0..<1000 where events.flatMap(\.frames).filter({ $0.contains("p1") }).count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        // "allow" with no gesture: refused, never sent.
        let allow = #"{"jsonrpc":"2.0","id":7,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"allow"}}"#
        #expect(await transport.send(connection: id, frames: [allow]) == .gestureRequired)
        // The real deny needs none.
        let deny = #"{"jsonrpc":"2.0","id":8,"method":"_acpmux/permission_respond","params":{"sessionId":"s","permissionId":"p1","optionId":"deny"}}"#
        #expect(await transport.send(connection: id, frames: [deny]) == nil)
    }

    // MARK: R8-3 and R8-4

    @Test func aDaemonFrameWithADuplicateKeyIsDroppedAndTheSocketCloses() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        for _ in 0..<1000 where !events.flatMap(\.frames).contains(where: { $0.contains("protocolVersion") }) { try? await Task.sleep(for: .milliseconds(5)) }
        // A notification arrives as a fresh serialization (the daemon's escaped key is decoded).
        server.push(#"{"jsonrpc":"2.0","method":"session/update","params":{"marker":"m-1"}}"#, to: 0)
        for _ in 0..<1000 where !events.flatMap(\.frames).contains(where: { $0.contains("m-1") }) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(events.flatMap(\.frames).contains { $0.contains(#""marker":"m-1""#) })
        // A status reply with two "peers" keys (R8-4) is dropped, and the socket closes.
        server.answer("_acpmux/status", with: #"{"peers":[{"name":"a"}],"peers":[{"name":"b","webUrl":"secret"}]}"#)
        _ = await transport.send(connection: id, frames: [#"{"jsonrpc":"2.0","id":9,"method":"_acpmux/status","params":{}}"#])
        for _ in 0..<1000 where !events.contains(where: { $0.closed != nil }) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!events.flatMap(\.frames).contains { $0.contains("secret") || $0.contains(#""name":"a""#) || $0.contains(#""name":"b""#) })
        #expect(events.contains { $0.closed?.error == .duplicateKey }, "\(events.compactMap(\.closed))")
    }

    @Test func aDaemonNotificationWithADuplicateKeyIsDropped() async throws {
        let server = AcpmuxStandInServer()
        try await server.start()
        defer { server.stop() }
        let transport = AgentPaneTransport()
        var events: [AgentPaneTransportEvent] = []
        transport.deliver = { event, done in events.append(event); done() }
        let id = try await transport.open(AcpmuxConnection(url: server.url, dashboardToken: "t", localAppToken: nil))
        _ = await transport.send(connection: id, frames: [Self.initialize])
        server.push(#"{"jsonrpc":"2.0","method":"_acpmux/permission_pending","params":{"sessionId":"s","permissionId":"p1","permissionId":"p2","request":{"options":[]},"marker":"dup-1"}}"#, to: 0)
        for _ in 0..<1000 where !events.contains(where: { $0.closed != nil }) { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!events.flatMap(\.frames).contains { $0.contains("dup-1") })
        #expect(events.contains { $0.closed?.error == .duplicateKey })
    }
}
