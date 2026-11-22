import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

@Suite(.timeLimit(.minutes(1))) struct ConnectionTests {
    static let identify = #"{"app":"cmux-tui","version":"0.1.0","protocol":12,"capabilities":["workspace-registry-v1","viewport-splits-v1","viewport-column-resize-v1","layout-undo-v1","view-attachment-lease-v1","view-attachment-detach-v1","attach-initial-size"],"session":"t","pid":1,"registry_id":"r","generation":"GEN","workspace_revision":0}"#

    /// Handles the handshake; delegates the rest.
    static func handshake(generation: @escaping @Sendable () -> String = { "GEN" },
                          other: @escaping @Sendable ([String: JSONValue], Int) -> [String]) -> @Sendable ([String: JSONValue]) -> [String] {
        { request in
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify":
                let body = identify.replacingOccurrences(of: "GEN", with: generation())
                return [#"{"id":\#(id),"ok":true,"data":\#(body)}"#]
            case "set-client-info", "subscribe":
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            default:
                return other(request, id)
            }
        }
    }

    @Test func outOfOrderResponsesResolveByID() async throws {
        // Hold the first ping's reply until the second arrives, then answer
        // both in reverse order.
        let held = Mutex<[Int]>([])
        let server = try FakeDaemonServer(handler: Self.handshake { request, id in
            guard request["cmd"]?.stringValue == "list-agents" else { return [] }
            let ids = held.withLock { ids -> [Int] in
                ids.append(id)
                return ids
            }
            guard ids.count == 2 else { return [] }
            return ids.reversed().map { #"{"id":\#($0),"ok":true,"data":{"agents":[{"surface":\#($0),"state":"idle","source":"hook","session":null,"updated_at_ms":1}]}}"# }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        async let first = connection.request(ListAgentsRequest())
        try await Task.sleep(for: .milliseconds(50)) // order the two writes; test-only
        async let second = connection.request(ListAgentsRequest())
        let (a, b) = try await (first, second)
        #expect(a.agents.first?.surface.rawValue != b.agents.first?.surface.rawValue)
        let ids = held.withLock { $0 }
        #expect(a.agents.first?.surface.rawValue == UInt64(ids[0]))
        #expect(b.agents.first?.surface.rawValue == UInt64(ids[1]))
        await connection.close()
    }

    @Test func idlessErrorResolvesOldestPendingAndCommandErrorsCarryMessage() async throws {
        let server = try FakeDaemonServer(handler: Self.handshake { request, id in
            switch request["cmd"]?.stringValue {
            case "close-pane": return [#"{"id":\#(id),"ok":false,"error":"unknown pane 99"}"#]
            case "rename-pane": return [#"{"ok":false,"error":"bad request: missing field"}"#]
            default: return []
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        await #expect(throws: DaemonError.command(cmd: "close-pane", message: "unknown pane 99", code: nil)) {
            try await connection.closePane(99)
        }
        await #expect(throws: DaemonError.command(cmd: "rename-pane", message: "bad request: missing field", code: nil)) {
            try await connection.renamePane(1, to: "x")
        }
        await connection.close()
    }

    @Test func eventsAfterHandshakeFollowConnected() async throws {
        let server = try FakeDaemonServer(handler: Self.handshake { request, id in
            if request["cmd"]?.stringValue == "list-workspaces" {
                return [
                    #"{"event":"title-changed","surface":3,"title":"vim"}"#,
                    #"{"id":\#(id),"ok":true,"data":{"workspace_revision":0,"workspaces":[]}}"#,
                ]
            }
            return []
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        var iterator = connection.events.makeAsyncIterator()
        guard let first = try await iterator.next(), case .connected(let identity, let changed) = first.event else {
            Issue.record("first event is not .connected")
            return
        }
        #expect(identity.generation == "GEN")
        #expect(changed == false)
        let (_, barrier) = try await connection.snapshot()
        let title = try #require(try await iterator.next())
        #expect(title.event == .titleChanged(surface: 3, title: "vim"))
        // The title event was on the wire before the snapshot result, so the
        // snapshot's barrier covers it.
        #expect(title.sequence > first.sequence)
        #expect(title.sequence <= barrier)
        await connection.close()
    }

    @Test func reconnectReportsGenerationChangeAndFailsPending() async throws {
        let generation = Mutex("GEN1")
        let server = try FakeDaemonServer(handler: Self.handshake(generation: { generation.withLock { $0 } }) { _, _ in [] })
        defer { server.stop() }
        // The fake accepts one client per server, so the provider moves the
        // connection to a fresh server on reconnect.
        let second = try FakeDaemonServer(handler: Self.handshake(generation: { "GEN2" }) { _, _ in [] })
        defer { second.stop() }
        let attempts = Mutex(0)
        let paths = [server.path, second.path]
        let connection = DaemonConnection(clock: ImmediateClock()) {
            let index = attempts.withLock { value -> Int in
                defer { value += 1 }
                return min(value, 1)
            }
            return DaemonEndpoint(socketPath: paths[index])
        }
        try await connection.start()
        var iterator = connection.events.makeAsyncIterator()
        guard case .connected? = try await iterator.next()?.event else {
            Issue.record("missing first connect")
            return
        }
        // A request the daemon never answers fails when the socket drops.
        let pending = Task { try await connection.request(ListAgentsRequest()) }
        try await Task.sleep(for: .milliseconds(50))
        server.disconnectClient()
        await #expect(throws: DaemonError.self) { try await pending.value }
        guard case .disconnected? = try await iterator.next()?.event else {
            Issue.record("missing disconnect")
            return
        }
        guard case .connected(let identity, let changed)? = try await iterator.next()?.event else {
            Issue.record("missing reconnect")
            return
        }
        #expect(identity.generation == "GEN2")
        #expect(changed)
        await connection.close()
    }

    @Test func incompatibleDaemonIsRejected() async throws {
        let server = try FakeDaemonServer { request in
            let id = request["id"]?.intValue ?? 0
            let body = ConnectionTests.identify.replacingOccurrences(of: #""protocol":12"#, with: #""protocol":11"#)
            return [#"{"id":\#(id),"ok":true,"data":\#(body)}"#]
        }
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        await #expect(throws: DaemonError.unsupportedProtocol(11)) { try await connection.start() }
    }

    @Test func tabToNewWorkspaceFallsBackWhenDaemonLacksTheCommand() async throws {
        let seen = Mutex<[String]>([])
        let server = try FakeDaemonServer(handler: Self.handshake { request, id in
            let cmd = request["cmd"]?.stringValue ?? ""
            seen.withLock { $0.append(cmd) }
            switch cmd {
            case "move-tab-to-new-workspace":
                return [#"{"ok":false,"error":"bad request: unknown variant `move-tab-to-new-workspace`, expected one of `identify`"}"#]
            case "move-tab-to-workspace":
                #expect(request["workspace"] == nil)
                return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            case "move-tab-to-split":
                return [#"{"ok":false,"error":"bad request: unknown variant `move-tab-to-split`"}"#]
            default:
                return []
            }
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        try await connection.start()
        _ = try await connection.moveTabToNewWorkspace(3, transaction: "tx")
        await #expect(throws: DaemonError.missingCapabilities([DaemonCapabilities.shared.tabDrag])) {
            try await connection.moveTabToSplit(3, pane: 4, edge: .right)
        }
        // Without tab-drag-v1 neither drag command reaches the daemon.
        #expect(seen.withLock { $0 }.last == "move-tab-to-workspace")
        #expect(!seen.withLock { $0 }.contains("move-tab-to-new-workspace"))
        #expect(!seen.withLock { $0 }.contains("move-tab-to-split"))
        await connection.close()
    }
}
