import CMUXMobileCore
import CmuxIrohTransport
import Foundation
import IrohLib
import Testing
@testable import CmuxIrxTransport

/// Opt-in network proof using the public Iroh relay fleet and two real peers.
/// This verifies relay-to-IP migration locally, not traversal across two NATs.
@Suite(.timeLimit(.minutes(1)))
struct IrxPathMigrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_IROH_PUBLIC_RELAY_TEST"] == "1"))
    func publicRelayMigratesToDirectWithoutReplacingConnection() async throws {
        let server = try await endpoint()
        let client = try await endpoint()
        do {
            let completed = try await withIrxDeadline(.seconds(45), onTimeout: {
                try? await client.close()
                try? await server.close()
            }) {
                await server.online()
                await client.online()
                let relay = try #require(server.addr().relayUrl())
                let accepting = Task {
                    let incoming = try #require(await server.acceptNext())
                    return try await incoming.accept().connect()
                }
                let raw = try await client.connect(
                    addr: EndpointAddr(id: server.id(), relayUrl: relay, addresses: []),
                    alpn: IrxProtocol().alpnData)
                let accepted = try await accepting.value
                let log = DiagnosticLog(capacity: 64, role: .iosClient)
                let (events, continuation) = AsyncStream<DiagnosticEvent>.makeStream()
                log.setEventTap { continuation.yield($0) }
                defer { continuation.finish() }
                let connection = IrxConnection(connection: raw, role: .dialer,
                    journal: IrxLiveTestSupport.journal(), diagnosticLog: log)
                let originalID = raw.stableId()
                #expect(raw.paths().contains { $0.isSelected && $0.isRelay })
                try await roundTrip(client: raw, server: accepted, message: "relay")

                await connection.authorizeDirectPaths()
                try await accepted.authorizeNatTraversal()
                var initial: DiagnosticEvent?
                var migration: DiagnosticEvent?
                for await event in events {
                    if event.code == .selectedPathChanged { initial = event }
                    if event.code == .transportPathEvent,
                       event.a == CmxIrohConnectionPathEventKind.selected.rawValue,
                       event.diagnosticPathKind == .privateNetwork || event.diagnosticPathKind == .direct {
                        migration = event
                        break
                    }
                }
                let selected = try #require(migration)
                #expect(initial?.diagnosticPathKind == .relay)
                #expect(selected.c == initial?.c)
                #expect(selected.surface == initial?.surface)
                #expect(raw.stableId() == originalID)
                #expect(raw.paths().contains { $0.isSelected && $0.isIp })
                try await roundTrip(client: raw, server: accepted, message: "direct")
                print("Iroh migration verified: relay -> \(selected.diagnosticPathKind == .privateNetwork ? "private_network" : "direct"), same connection, bidirectional data before and after")
                await connection.close(code: .userRequested, origin: .local)
                return true
            }
            #expect(completed == true, "Expected relay selection and a native direct-path selection within 45 seconds")
        } catch {
            try? await client.close()
            try? await server.close()
            throw error
        }
        try await client.close()
        try await server.close()
    }

    private func endpoint() async throws -> Endpoint {
        try await Endpoint.bind(options: EndpointOptions(
            preset: presetMinimal(), alpns: [IrxProtocol().alpnData],
            relayMode: RelayMode.defaultMode(), portMappingEnabled: false,
            deferNatTraversalUntilAuthorized: true,
            initialMaxConcurrentBiStreams: 4, initialMaxConcurrentUniStreams: 0))
    }

    private func roundTrip(client: Connection, server: Connection, message: String) async throws {
        let payload = Data(message.utf8)
        let outgoing = try await client.openBi()
        try await outgoing.send().writeAll(buf: payload)
        try await outgoing.send().finish()
        let incoming = try await server.acceptBi()
        #expect(try await incoming.recv().readToEnd(sizeLimit: 32) == payload)
        try await incoming.send().writeAll(buf: payload)
        try await incoming.send().finish()
        #expect(try await outgoing.recv().readToEnd(sizeLimit: 32) == payload)
    }
}
