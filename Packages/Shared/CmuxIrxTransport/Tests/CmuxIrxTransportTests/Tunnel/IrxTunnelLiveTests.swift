import Foundation
import IrohLib
import Testing

@testable import CmuxIrxTransport

/// The browser tunnel over two real iroh endpoints on loopback: the phone
/// side (`IrxTunnelClient`) opens lanes, the Mac side (`IrxTunnelHost`)
/// serves them with the real Network.framework connector.
@Suite("tunnel over live QUIC", .serialized)
struct IrxTunnelLiveTests {
    private struct Pair {
        let client: IrxConnection
        let host: IrxTunnelHost
        let close: @Sendable () async -> Void
    }

    private func connectPair(optIn: Bool = false) async throws -> Pair {
        let journal = IrxLiveTestSupport.journal()
        let serverEndpoint = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 1)
        let clientEndpoint = try await IrxLiveTestSupport.bindLoopback(
            seed: IrxLiveTestSupport.identitySeed(), remoteBiCredit: 0)
        let host = IrxTunnelHost(
            policy: { IrxTunnelDestinationPolicy(allowsNonLoopbackHosts: optIn) },
            isAuthorized: { true },
            journal: journal
        )
        let serverTask = Task {
            guard let incoming = await serverEndpoint.acceptNext() else { return }
            let accepting = try await incoming.accept()
            let connection = try await accepting.connect()
            let irx = IrxConnection(connection: connection, role: .acceptor, journal: journal)
            guard await IrxAdmission().performServer(
                connection: irx,
                judgment: IrxLiveTestSupport.fixedJudgment(accepting: "good-grant"),
                journal: journal
            ) != nil else { return }
            while let lane = await irx.acceptLane() {
                await host.accept(lane)
            }
            await host.stop()
        }
        let connection = try await clientEndpoint.connect(
            addr: IrxLiveTestSupport.loopbackAddr(of: serverEndpoint), alpn: IrxProtocol().alpnData)
        let irx = IrxConnection(connection: connection, role: .dialer, journal: journal)
        _ = try await IrxAdmission().performClient(connection: irx, grantJWS: "good-grant", journal: journal)
        return Pair(client: irx, host: host) {
            await irx.close(code: .userRequested, origin: .local)
            serverTask.cancel()
            try? await serverEndpoint.close()
            try? await clientEndpoint.close()
        }
    }

    @Test("bytes and a half-close cross the tunnel to a loopback server")
    func echoWithHalfClose() async throws {
        let server = try TunnelTestTCPServer(mode: .echo)
        defer { server.stop() }
        let pair = try await connectPair()
        let lane = try await IrxTunnelClient(connection: pair.client).connect(host: "localhost", port: server.port)
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try await lane.writer.write(payload)
        // Half-close: the server sees EOF, then answers with a trailer.
        await lane.writer.finish()
        var received = Data()
        while let chunk = try await lane.reader.readRaw() {
            received.append(chunk)
        }
        #expect(received == payload + Data("<eof>".utf8))
        await pair.close()
    }

    @Test("refused, denied, and metadata destinations fail with their status")
    func refusalsCarryStatus() async throws {
        let pair = try await connectPair(optIn: true)
        // Find a closed port: bind and release one.
        let closedPort: Int = try {
            let probe = try TunnelTestTCPServer(mode: .echo)
            defer { probe.stop() }
            return probe.port
        }()
        await #expect(throws: IrxTunnelOpenError(status: .refused)) {
            _ = try await IrxTunnelClient(connection: pair.client).connect(host: "127.0.0.1", port: closedPort)
        }
        await #expect(throws: IrxTunnelOpenError(status: .denied)) {
            _ = try await IrxTunnelClient(connection: pair.client).connect(host: "169.254.169.254", port: 80)
        }
        await pair.close()
    }

    @Test("the listening-ports lane lists a loopback listener")
    func listeningPortsLane() async throws {
        let server = try TunnelTestTCPServer(mode: .echo)
        defer { server.stop() }
        let pair = try await connectPair()
        let reply = try await IrxTunnelClient(connection: pair.client).listeningPorts()
        #expect(reply.ports.contains(IrxListeningPort(port: server.port, address: "127.0.0.1")))
        #expect(reply.allowsNonLoopbackHosts == false)
        await pair.close()
    }
}
