import Foundation
import Testing
@testable import CmuxNextDaemon

/// The connection opens `session.events` after connecting to a daemon whose
/// `identify` advertises `state-resources-v1`, routes its lines with the raw
/// events, opens none on a daemon without it, and sends state mutations with
/// idempotency keys.
@Suite(.timeLimit(.minutes(1))) struct SessionEventsConnectionTests {
    static func server(snapshot: String, state: Bool = true, _ log: PlacementTests.Log) throws -> FakeDaemonServer {
        let identify = ConnectionTests.identify.replacingOccurrences(
            of: #""attach-initial-size"]"#, with: #""attach-initial-size","state-resources-v1"]"#)
        let handle = ConnectionTests.handshake { request, _ in
            guard request["protocol"]?.stringValue == "cmux.protocol/2" else { return [] }
            log.append(request)
            let id = request["id"]?.stringValue ?? ""
            let params = PlacementTests.object(request["params"]) ?? [:]
            switch request["operation"]?.stringValue {
            case "session.events":
                let stream = params["stream_id"]?.stringValue ?? ""
                // One JSON line on the wire.
                let line = snapshot.replacingOccurrences(of: "stream_1", with: stream).replacingOccurrences(of: "\n", with: "")
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"stream_id":"\#(stream)"}}"#, line]
            case "stream.cancel":
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{}}"#]
            default:
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"value":{"id":"tgrp_new"},"generation":"g","revision":"9","replayed":false}}"#]
            }
        }
        return try FakeDaemonServer(handler: { request in
            guard state, request["cmd"]?.stringValue == "identify" else { return handle(request) }
            let id = request["id"]?.intValue ?? 0
            return [#"{"id":\#(id),"ok":true,"data":\#(identify.replacingOccurrences(of: "GEN", with: "GEN"))}"#]
        })
    }

    static func connect(_ server: FakeDaemonServer) async throws -> DaemonConnection {
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path),
                                          configuration: .init(terminalEnvironment: nil, sessionEvents: true))
        try await connection.start()
        return connection
    }

    /// The first `.sessionState` event the connection routes.
    static func firstSessionItem(_ connection: DaemonConnection) async throws -> SessionStreamItem? {
        for try await envelope in connection.events {
            if case .sessionState(let item) = envelope.event { return item }
        }
        return nil
    }

    @Test func stateSnapshotReachesTheEventStream() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(snapshot: SessionStateTests.snapshot, log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        let item = try await Self.firstSessionItem(connection)
        guard case .snapshot(let mirror)? = item else {
            Issue.record("expected a snapshot, got \(String(describing: item))")
            return
        }
        #expect(mirror.closed.map(\.id) == ["closed_1"])
        let open = try #require(log.all.first)
        #expect(open["operation"]?.stringValue == "session.events")
        #expect(open["idempotency_key"] == nil)
        let stream = try #require(PlacementTests.object(open["params"])?["stream_id"]?.stringValue)
        #expect(stream.hasPrefix("stream_") && stream.count == 39)
        await connection.close()
    }

    @Test func aDaemonWithoutTheCapabilityGetsNoStream() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(snapshot: SessionStateTests.snapshot, state: false, log)
        defer { server.stop() }
        let connection = try await Self.connect(server)
        // A later request on the same connection: the stream would have been
        // opened before it (right after the handshake).
        try await connection.state.setTabPinned(ResourceID(rawValue: "tab_a"), true)
        #expect(log.all.compactMap { $0["operation"]?.stringValue } == ["tab.pin"])
        await connection.close()
    }

    @Test func stateMutationsCarryKeysDerivedFromTheAction() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(snapshot: SessionStateTests.snapshot, log)
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: .init(terminalEnvironment: nil))
        try await connection.start()
        let scope = DaemonCommandScope(idempotencyKey: "retry-me")
        let created = try await DaemonCommandScope.$current.withValue(scope) {
            try await connection.state.createTabGroup(tabs: [ResourceID(rawValue: "tab_a")], name: "g", color: "blue")
        }
        #expect(created.id == "tgrp_new")
        let again = DaemonCommandScope(idempotencyKey: "retry-me")
        _ = try await DaemonCommandScope.$current.withValue(again) {
            try await connection.state.createTabGroup(tabs: [ResourceID(rawValue: "tab_a")], name: "g", color: "blue")
        }
        try await connection.state.setTabPinned(ResourceID(rawValue: "tab_a"), true)
        let sent = log.all
        #expect(sent.map { $0["operation"]?.stringValue } == ["tab_group.create", "tab_group.create", "tab.pin"])
        let keys = sent.compactMap { $0["idempotency_key"]?.stringValue }
        #expect(keys.count == 3)
        #expect(keys[0] == keys[1], "a retried action replays with the same key")
        #expect(keys[2] != keys[0])
        let params = try #require(PlacementTests.object(sent[0]["params"]))
        #expect(params["tabs"] == .array([.string("tab_a")]) && params["color"] == .string("blue"))
        await connection.close()
    }
}
