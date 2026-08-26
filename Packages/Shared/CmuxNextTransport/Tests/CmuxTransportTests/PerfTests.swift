import Foundation
import Testing

@testable import CmuxNextTransport

/// P3 (harness spec 2.4): measurements exist BECAUSE decision D5 chose JSON
/// everywhere. Round 1 reports numbers; Aziz sets the thresholds, which then
/// become contractual like 8.4.
@Suite("Wire overhead (always-on, deterministic)")
struct OverheadTests {
    @Test("JSON+base64 wire overhead for terminal-shaped chunks is bounded and known")
    func overheadRatio() throws {
        let encoder = FrameEncoder()
        // base64 alone is 1.333x; the JSON envelope + seq + sha256 hex are a
        // fixed ~127B, so SMALL frames pay proportionally more. Measured
        // round 1: 256B -> 1.86x, 1KiB -> 1.49x, 4KiB -> 1.38x, 16KiB -> 1.36x.
        // The documented D5 cost; a binary cmux/peer/2 would be ~1.0x.
        let bounds = [256: 1.9, 1_024: 1.55, 4_096: 1.42, 16_384: 1.40]
        for (size, bound) in bounds.sorted(by: { $0.key < $1.key }) {
            let frame = TerminalTraffic.chunk(seq: 1, size: size, seed: 3)
            let encoded = try encoder.encode(frame)
            let ratio = Double(encoded.count) / Double(size)
            print("[overhead] payload \(size)B -> wire \(encoded.count)B, ratio \(String(format: "%.3f", ratio))")
            #expect(ratio < bound)
        }
    }
}

/// Gated timing runs (CMUX_LITE_PERF=1): real QUIC over the loopback
/// interface, round-trip echo through the full stack (JSON encode, QUIC
/// stream, host echo service, decode, checksum validation).
@Suite(
    "Throughput, live QUIC (P3)",
    .enabled(if: ProcessInfo.processInfo.environment["CMUX_LITE_PERF"] == "1"))
struct PerfTests {
    @Test("Round-trip echo throughput over live QUIC")
    func echoThroughput() async throws {
        let signer = GrantSigner()
        let now: Int64 = 1_000_000
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let mac = PeerIdentity.generate(appIdentity: "dev.cmux.lite.mac", deviceID: "m")
        let phone = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "p")
        let grant = try signer.mint(
            accountID: "a", deviceID: "p", devicePublicKey: phone.publicKeyData,
            appIdentity: phone.appIdentity, grantID: "g", issuedAt: now)

        let server = try await IrohSubstrate.endpoint(identity: mac, minimalLoopback: true)
        let client = try await IrohSubstrate.endpoint(identity: phone, minimalLoopback: true)
        let serveLoop = Task {
            while let conn = try? await IrohSubstrate.acceptOne(endpoint: server) {
                await host.serve(connection: conn, now: now)
            }
        }
        let conn = try await IrohSubstrate.dial(
            endpoint: client, to: IrohSubstrate.directAddr(of: server))
        _ = try await TransportClient.connect(connection: conn, identity: phone, grant: grant)

        let echo = await conn.lane(TransportHost.echoLaneName)
        let chunkSize = 16_384
        let count = 500
        let clock = ContinuousClock()
        var validator = TrafficValidator()
        let start = clock.now
        for seq in Int64(0)..<Int64(count) {
            try await echo.send(TerminalTraffic.chunk(seq: seq, size: chunkSize, seed: 77))
            if let reply = await echo.receive() {
                validator.ingest(reply)
            }
        }
        let elapsed = clock.now - start
        #expect(validator.received == count)
        #expect(validator.isClean)
        let payloadMB = Double(chunkSize * count) / 1_048_576
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        print(
            "[perf] \(count) x \(chunkSize)B round trips in \(elapsed): "
                + String(format: "%.1f MB/s payload round-trip, %.3f ms/chunk", payloadMB * 2 / seconds, seconds * 1000 / Double(count)))

        await conn.closeAll()
        serveLoop.cancel()
        try await server.close()
        try await client.close()
    }
}
