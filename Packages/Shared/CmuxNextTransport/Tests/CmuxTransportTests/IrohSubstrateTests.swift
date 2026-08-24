import Foundation
import Testing

@testable import CmuxNextTransport

/// Live QUIC over the loopback interface: two real iroh endpoints in one
/// process, no relays, no discovery. The SAME host logic that passed the
/// in-memory suite runs here unchanged; only the substrate differs. That is
/// the seam doing its job.
@Suite("iroh substrate, live QUIC (P1b)", .serialized)
struct IrohSubstrateTests {
    let signer = GrantSigner()
    let now: Int64 = 1_000_000

    private func mint(
        for identity: PeerIdentity, grantID: String = "g-1", expiresAt: Int64? = nil
    ) throws -> PairingGrant {
        try signer.mint(
            accountID: "acct-1", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: grantID, issuedAt: now, expiresAt: expiresAt)
    }

    @Test("Dial, admit, and echo terminal-shaped traffic over real QUIC")
    func dialAdmitEcho() async throws {
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let mac = PeerIdentity.generate(appIdentity: "dev.cmux.lite.mac", deviceID: "mac-1")
        let phone = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: phone)

        let server = try await IrohSubstrate.endpoint(identity: mac, minimalLoopback: true)
        let client = try await IrohSubstrate.endpoint(identity: phone, minimalLoopback: true)
        let serveLoop = Task {
            while let conn = try? await IrohSubstrate.acceptOne(endpoint: server) {
                await host.serve(connection: conn, now: now)
            }
        }

        let conn = try await IrohSubstrate.dial(
            endpoint: client, to: IrohSubstrate.directAddr(of: server))

        // Both directions were key-authenticated in the QUIC handshake: the
        // dialer proved it's talking to the real Mac (3.5, both ways).
        #expect(await conn.authenticatedRemoteKey == mac.publicKeyData)
        let outcome = try await TransportClient.connect(
            connection: conn, identity: phone, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))

        let echo = await conn.lane(TransportHost.echoLaneName)
        var validator = TrafficValidator()
        for seq in Int64(0)..<50 {
            try await echo.send(TerminalTraffic.chunk(seq: seq, size: 2_048, seed: 11))
            if let reply = await echo.receive() {
                validator.ingest(reply)
            }
        }
        #expect(validator.received == 50)
        #expect(validator.isClean)
        #expect(await host.counters.admissions == 1)

        await conn.closeAll()
        serveLoop.cancel()
        try await server.close()
        try await client.close()
    }

    @Test("A denial is readable over real QUIC before the host closes (3.3)")
    func denialReadableOverQUIC() async throws {
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let mac = PeerIdentity.generate(appIdentity: "dev.cmux.lite.mac", deviceID: "mac-1")
        let phone = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: phone, expiresAt: now - 10)  // already expired

        let server = try await IrohSubstrate.endpoint(identity: mac, minimalLoopback: true)
        let client = try await IrohSubstrate.endpoint(identity: phone, minimalLoopback: true)
        let serveLoop = Task {
            while let conn = try? await IrohSubstrate.acceptOne(endpoint: server) {
                await host.serve(connection: conn, now: now)
            }
        }

        let conn = try await IrohSubstrate.dial(
            endpoint: client, to: IrohSubstrate.directAddr(of: server))
        // No drains, no timers (3.3 v6): even if the ctl.deny frame loses the
        // race against close, the code arrives in the connection termination.
        let outcome = try await TransportClient.connect(
            connection: conn, identity: phone, grant: grant)
        #expect(outcome == .denied(.expired))

        await conn.closeAll()
        serveLoop.cancel()
        try await server.close()
        try await client.close()
    }

    @Test("The denial code survives in the connection termination alone (3.3, no timing)")
    func denialCarriedByTerminationChannel() async throws {
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let mac = PeerIdentity.generate(appIdentity: "dev.cmux.lite.mac", deviceID: "mac-1")
        let phone = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: phone, expiresAt: now - 10)

        let server = try await IrohSubstrate.endpoint(identity: mac, minimalLoopback: true)
        let client = try await IrohSubstrate.endpoint(identity: phone, minimalLoopback: true)
        let serveLoop = Task {
            while let conn = try? await IrohSubstrate.acceptOne(endpoint: server) {
                await host.serve(connection: conn, now: now)
            }
        }

        let conn = try await IrohSubstrate.dial(
            endpoint: client, to: IrohSubstrate.directAddr(of: server))
        let control = await conn.lane("ctl")
        try await control.send(Frame.hello(identity: phone, grant: grant))
        // Deliberately DISCARD every frame the host manages to deliver, then
        // recover the reason purely from the substrate's close mechanism.
        while await control.receive() != nil {}
        let termination = await conn.termination()
        #expect(termination == ConnectionTermination(code: "expired"))

        serveLoop.cancel()
        try await server.close()
        try await client.close()
    }

    @Test("A stolen grant fails over real QUIC: the handshake key wins (3.5)")
    func stolenGrantDeniedByHandshakeKey() async throws {
        let host = TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
        let mac = PeerIdentity.generate(appIdentity: "dev.cmux.lite.mac", deviceID: "mac-1")
        let victim = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let attacker = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let victimGrant = try mint(for: victim)

        let server = try await IrohSubstrate.endpoint(identity: mac, minimalLoopback: true)
        // The attacker's endpoint: iroh authenticates THIS key in the
        // handshake, no matter what the hello claims.
        let client = try await IrohSubstrate.endpoint(identity: attacker, minimalLoopback: true)
        let serveLoop = Task {
            while let conn = try? await IrohSubstrate.acceptOne(endpoint: server) {
                await host.serve(connection: conn, now: now)
            }
        }

        let conn = try await IrohSubstrate.dial(
            endpoint: client, to: IrohSubstrate.directAddr(of: server))
        // The hello impersonates the victim wholesale: victim's key, victim's
        // grant. Over loopback this needed a simulated authenticated key; over
        // real QUIC the substrate key is simply the truth.
        let outcome = try await TransportClient.connect(
            connection: conn, identity: victim, grant: victimGrant)
        #expect(outcome == .denied(.keyMismatch))
        #expect(await host.counters.admissions == 0)

        await conn.closeAll()
        serveLoop.cancel()
        try await server.close()
        try await client.close()
    }
}
