import Foundation
import IrohLib
import Testing

@testable import CmuxNextTransport

/// Live relay-fleet verification (P1e, harness spec 2.2): both endpoints are
/// configured against a REAL cmux relay with REAL endpoint-bound tokens, and
/// the dial address carries NO direct candidates, so establishment can only
/// happen through the relay. Gated on CMUX_LITE_RELAY_CONFIG (a JSON file
/// produced by cmux-lite/relay-e2e.py, which mints the 300s tokens); absent
/// config skips, so the default suite stays offline-clean.
@Suite(
    "relay fleet, live (P1e)", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CMUX_LITE_RELAY_CONFIG"] != nil))
struct RelayE2ETests {
    struct Peer: Decodable {
        let secretHex: String
        let token: String
    }

    struct Config: Decodable {
        let relayUrl: String
        let server: Peer
        let client: Peer
    }

    static func loadConfig() throws -> Config {
        let path = ProcessInfo.processInfo.environment["CMUX_LITE_RELAY_CONFIG"]!
        return try JSONDecoder().decode(
            Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    static func data(fromHex hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    @Test("Relay-only dial, admit, and echo through the real fleet")
    func relayOnlyAdmitEcho() async throws {
        let config = try Self.loadConfig()
        let signer = GrantSigner()
        let now = Int64(Date().timeIntervalSince1970)
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))

        let mac = PeerIdentity(
            appIdentity: "dev.cmux.lite.mac", deviceID: "relay-mac-1",
            privateKeyData: Self.data(fromHex: config.server.secretHex))
        let phone = PeerIdentity(
            appIdentity: "dev.cmux.lite", deviceID: "relay-phone-1",
            privateKeyData: Self.data(fromHex: config.client.secretHex))
        let grant = try signer.mint(
            accountID: "acct-relay", deviceID: phone.deviceID,
            devicePublicKey: phone.publicKeyData, appIdentity: phone.appIdentity,
            grantID: "g-relay-1", issuedAt: now)

        let clock = ContinuousClock()
        let bootStart = clock.now
        let server = try await IrohSubstrate.endpoint(
            identity: mac,
            relays: [IrohSubstrate.RelayAccess(url: config.relayUrl, authToken: config.server.token)])
        // The host must be registered with its home relay before a
        // relay-only dial can find it.
        await server.online()
        let serverOnline = clock.now
        print("[relay-e2e] server online via \(config.relayUrl) in \(serverOnline - bootStart)")

        let client = try await IrohSubstrate.endpoint(
            identity: phone,
            relays: [IrohSubstrate.RelayAccess(url: config.relayUrl, authToken: config.client.token)])
        await client.online()
        print("[relay-e2e] client online in \(clock.now - serverOnline)")

        let serveLoop = Task {
            while let conn = try? await IrohSubstrate.acceptOne(endpoint: server) {
                await host.serve(connection: conn, now: now)
            }
        }

        // NO direct addresses: establishment must traverse the relay. (iroh
        // may hole-punch a direct path AFTERWARDS; that migration is the
        // production behavior and is fine.)
        let dialStart = clock.now
        let conn = try await IrohSubstrate.dial(
            endpoint: client,
            to: try IrohSubstrate.relayAddr(id: mac.publicKeyData, relayUrl: config.relayUrl))
        let outcome = try await TransportClient.connect(
            connection: conn, identity: phone, grant: grant)
        let ready = clock.now
        #expect(outcome == .admitted(sessionID: "s1"))
        print("[relay-e2e] dial -> admitted in \(ready - dialStart)")

        let echo = await conn.lane(TransportHost.echoLaneName)
        var validator = TrafficValidator()
        let echoStart = clock.now
        for seq in Int64(0)..<50 {
            try await echo.send(TerminalTraffic.chunk(seq: seq, size: 4_096, seed: 55))
            if let reply = await echo.receive() {
                validator.ingest(reply)
            }
        }
        let echoEnd = clock.now
        #expect(validator.received == 50)
        #expect(validator.isClean)
        print("[relay-e2e] 50x4KiB round trips in \(echoEnd - echoStart)")

        // Denial still readable when the only path is a relay (3.3).
        let stranger = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "x")
        let strangerGrant = try signer.mint(
            accountID: "acct-relay", deviceID: "x", devicePublicKey: stranger.publicKeyData,
            appIdentity: stranger.appIdentity, grantID: "g-x", issuedAt: now,
            expiresAt: now - 10)
        await host.revokeGrant(id: "g-x")
        let conn2 = try await IrohSubstrate.dial(
            endpoint: client,
            to: try IrohSubstrate.relayAddr(id: mac.publicKeyData, relayUrl: config.relayUrl))
        let denied = try await TransportClient.connect(
            connection: conn2, identity: phone, grant: strangerGrant)
        #expect(denied == .denied(.keyMismatch))  // phone's key, stranger's grant

        await conn.closeAll()
        serveLoop.cancel()
        try await server.close()
        try await client.close()
    }

    /// The phone's 08-20 field failure, reproduced headlessly: a VALID fleet
    /// token presented by an endpoint whose key it was not minted for. The
    /// relay refuses the upgrade, so with no direct candidates the dial can
    /// never establish; the app-visible symptom is a silent dial timeout.
    @Test("A token bound to a different endpoint key never establishes")
    func wrongKeyTokenNeverEstablishes() async throws {
        let config = try Self.loadConfig()
        let signer = GrantSigner()
        let now = Int64(Date().timeIntervalSince1970)
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))

        let mac = PeerIdentity(
            appIdentity: "dev.cmux.lite.mac", deviceID: "relay-mac-1",
            privateKeyData: Self.data(fromHex: config.server.secretHex))
        let server = try await IrohSubstrate.endpoint(
            identity: mac,
            relays: [IrohSubstrate.RelayAccess(url: config.relayUrl, authToken: config.server.token)])
        await server.online()
        let serveLoop = Task {
            while let conn = try? await IrohSubstrate.acceptOne(endpoint: server) {
                await host.serve(connection: conn, now: now)
            }
        }

        let imposter = PeerIdentity.generate(
            appIdentity: "dev.cmux.lite", deviceID: "imposter-phone")
        let client = try await IrohSubstrate.endpoint(
            identity: imposter,
            relays: [IrohSubstrate.RelayAccess(url: config.relayUrl, authToken: config.client.token)])

        let established = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                guard
                    let addr = try? IrohSubstrate.relayAddr(
                        id: mac.publicKeyData, relayUrl: config.relayUrl),
                    (try? await IrohSubstrate.dial(endpoint: client, to: addr)) != nil
                else { return false }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(!established)

        serveLoop.cancel()
        try await server.close()
        try await client.close()
    }
}
