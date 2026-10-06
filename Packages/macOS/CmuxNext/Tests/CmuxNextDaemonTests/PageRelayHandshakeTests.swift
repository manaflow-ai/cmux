import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// SECURITY (request-origin.md): the page relay connection says `client-hello {role: page_relay}`
/// right after `identify`, sends no label and no subscribe, and sends no page call before the
/// hello result; every relay request carries an origin claim. Against a daemon without
/// `origin-claim-v1` it does not connect at all.
@Suite(.timeLimit(.minutes(1))) struct PageRelayHandshakeTests {
    static let config = DaemonConnection.Configuration(requestTimeout: .milliseconds(800), snapshotTimeout: .milliseconds(800),
                                                       terminalEnvironment: nil, role: .pageRelay)

    static func server(_ log: PlacementTests.Log, capable: Bool) throws -> FakeDaemonServer {
        let identify = capable
            ? ConnectionTests.identify.replacingOccurrences(of: #""attach-initial-size""#, with: #""attach-initial-size","origin-claim-v1""#)
            : ConnectionTests.identify
        return try FakeDaemonServer(handler: { request in
            log.append(request)
            if request["protocol"]?.stringValue == "cmux.protocol/2" {
                let id = request["id"]?.stringValue ?? ""
                return [#"{"protocol":"cmux.protocol/2","type":"response","id":"\#(id)","ok":true,"result":{"value":{}}}"#]
            }
            let id = request["id"]?.intValue ?? 0
            switch request["cmd"]?.stringValue {
            case "identify": return [#"{"id":\#(id),"ok":true,"data":\#(identify)}"#]
            case "client-hello": return [#"{"id":\#(id),"ok":true,"data":{"connection_id":"c7"}}"#]
            default: return [#"{"id":\#(id),"ok":true,"data":{}}"#]
            }
        })
    }

    static func names(_ log: PlacementTests.Log) -> [String] {
        log.all.map { $0["cmd"]?.stringValue ?? $0["operation"]?.stringValue ?? "?" }
    }

    @Test func theRelayHelloComesRightAfterIdentifyAndBeforeAnyPageCall() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log, capable: true)
        defer { server.stop() }
        var config = Self.config
        let identity = PageRelayIdentity()
        config.relayIdentity = identity
        let relay = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: config)
        try await relay.start()
        #expect(identity.connectionID == "c7", "the hello's connection id is kept for confirmation tokens")
        _ = try await ResourceRelayClient(connection: relay).send(operation: "history.entries.list", params: [:], idempotencyKey: nil,
                                                                  origin: .object(["claim": .string("page")]))
        #expect(Self.names(log) == ["identify", "client-hello", "history.entries.list"], "no label, no subscribe, the call after the hello")
        #expect(log.all[1]["role"] == .string("page_relay"))
        #expect(log.all[2]["origin"] == .object(["claim": .string("page")]), "every relay request carries its origin claim")
        await relay.close()
    }

    @Test func aDaemonWithoutOriginClaimsGetsNoRelayConnection() async throws {
        let log = PlacementTests.Log()
        let server = try Self.server(log, capable: false)
        defer { server.stop() }
        let relay = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path), configuration: Self.config)
        await #expect(throws: DaemonError.self) { try await relay.start() }
        #expect(Self.names(log) == ["identify"], "no hello and no call to a daemon that cannot narrow them")
        await relay.close()
    }

    @Test func theConfirmationTokenIsBoundToTheParamsAsSent() throws {
        let sent = try ResourceRelayClient.paramsDigest(["b": .number(1), "a": .string("x")])
        let same = try ResourceRelayClient.paramsDigest(["a": .string("x"), "b": .number(1), "machine": .string("current"),
                                                         "session": .string("current")])
        #expect(sent == same, "the digest covers the wire params, defaults included, in canonical key order")
        #expect(try ResourceRelayClient.paramsDigest(["a": .string("y"), "b": .number(1)]) != sent)
    }
}
