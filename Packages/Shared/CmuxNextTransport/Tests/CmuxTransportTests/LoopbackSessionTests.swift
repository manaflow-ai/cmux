import Foundation
import Testing

@testable import CmuxNextTransport

@Suite("Loopback sessions (contract 3.x, 4.5, 1.4, 5.1)")
struct LoopbackSessionTests {
    let signer = GrantSigner()
    let now: Int64 = 1_000_000

    private func makeHost() -> TransportHost {
        TransportHost(verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
    }

    private func mintedIdentity(
        app: String, deviceID: String = "phone-1"
    ) throws -> (PeerIdentity, PairingGrant) {
        let identity = PeerIdentity.generate(appIdentity: app, deviceID: deviceID)
        let grant = try signer.mint(
            accountID: "acct-1", deviceID: deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: app,
            grantID: "g-\(app)", issuedAt: now)
        return (identity, grant)
    }

    @Test("Happy path: admitted in one round trip, then lossless ordered echo")
    func admitAndEcho() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity(app: "dev.cmux.lite")
        // The substrate authenticated the client's real key (3.5): the normal
        // case over iroh, exercised here through the seam.
        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)

        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))
        await serving

        let echo = await client.lane(TransportHost.echoLaneName)
        var validator = TrafficValidator()
        for seq in Int64(0)..<100 {
            try await echo.send(TerminalTraffic.chunk(seq: seq, size: 512, seed: 42))
            if let reply = await echo.receive() {
                validator.ingest(reply)
            }
        }
        #expect(validator.received == 100)
        #expect(validator.isClean)
        #expect(await host.counters.admissions == 1)
    }

    @Test("Natural connection loss reaps the session (the table never lies)")
    func connectionLossReapsSession() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity(app: "dev.cmux.lite")
        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))
        await serving
        #expect(await host.sessionCount == 1)

        // The 08-21 field deadlock: after a NATURAL death (no kill, no
        // supersession) the session stayed in the table, status reported the
        // phone as present, and the rig's rotation gate waited forever.
        await client.closeAll(reason: nil)
        var polls = 0
        while await host.sessionCount != 0, polls < 200 {
            try await Task.sleep(for: .milliseconds(10))
            polls += 1
        }
        #expect(await host.sessionCount == 0)
        #expect(await host.sessionDeviceIDs.isEmpty)
        let pushed = await host.pushRelayCredential(
            deviceID: identity.deviceID, appIdentity: identity.appIdentity,
            url: "https://usc1.relay.cmux.dev/", token: "tok")
        #expect(!pushed)
    }

    @Test("Zombie sessions are reaped by the substrate's own liveness signal")
    func closedConnectionsReapOnDemand() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity(app: "dev.cmux.lite")
        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        _ = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        await serving
        #expect(await host.reapClosedSessions() == 0)  // live: untouched
        #expect(await host.sessionCount == 1)

        // A silently dead peer: stream-EOF reaping can lag QUIC's timeout by
        // ~90s in the field, but isClosed knows immediately, so any table
        // consumer (status, push) sees the truth on demand.
        await client.closeAll(reason: nil)
        _ = await host.reapClosedSessions()
        #expect(await host.sessionCount == 0)
        let pushed = await host.pushRelayCredential(
            deviceID: identity.deviceID, appIdentity: identity.appIdentity,
            url: "https://usc1.relay.cmux.dev/", token: "tok")
        #expect(!pushed)
    }

    @Test("The substrate-authenticated key overrules a lying hello (3.5)")
    func substrateKeyOverrulesHello() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity(app: "dev.cmux.lite")
        let imposter = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")

        // The wire's encryption layer proved the IMPOSTER's key, but the
        // hello self-reports the victim's key alongside the victim's stolen
        // grant. Without substrate binding this would admit; with it, denied.
        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: imposter.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .denied(.keyMismatch))
        await serving
        #expect(await host.counters.admissions == 0)
    }

    @Test("A denial is readable before the connection closes (3.2, 3.3)")
    func denialReadableBeforeClose() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity(app: "dev.cmux.lite")
        await host.revokeGrant(id: grant.grantID)

        let (client, hostEnd) = LoopbackWire().makeEnds()
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        // The host denies and then closes the wire; the client must still read
        // the denial, never see a silent hang or a bare EOF.
        let outcome = try await TransportClient.connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .denied(.revoked))
        await serving
        #expect(await host.counters.denialsByCode["revoked"] == 1)
        #expect(await client.isClosed)
    }

    @Test("Supersession: a relaunched peer instantly replaces its dead session (4.5)")
    func supersession() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity(app: "dev.cmux.lite")

        // First connection admits. Its process then "dies" without closing
        // anything, exactly like an iOS app kill.
        let (firstClient, firstHostEnd) = LoopbackWire().makeEnds()
        async let firstServe: Void = host.serve(connection: firstHostEnd, now: now)
        let first = try await TransportClient.connect(
            connection: firstClient, identity: identity, grant: grant)
        #expect(first == .admitted(sessionID: "s1"))
        await firstServe

        // The relaunched app dials again with the same identity. It must be
        // admitted immediately; the old session must be closed as superseded,
        // not left blocking re-admission (the ~85s field lockout).
        let (secondClient, secondHostEnd) = LoopbackWire().makeEnds()
        async let secondServe: Void = host.serve(connection: secondHostEnd, now: now)
        let second = try await TransportClient.connect(
            connection: secondClient, identity: identity, grant: grant)
        #expect(second == .admitted(sessionID: "s2"))
        await secondServe

        // The old connection observed an ATTRIBUTED close (4.4): the reason
        // rides in the termination itself, no close frame exists (v7).
        let firstControl = await firstClient.lane("ctl")
        #expect(await firstControl.receive() == nil)
        #expect(await firstClient.termination() == ConnectionTermination(code: "superseded"))
        #expect(await firstClient.isClosed)
        #expect(await secondClient.isClosed == false)
        #expect(await host.counters.closesByCode["superseded"] == 1)
    }

    @Test("Same device, different app identity: separate peers, no supersession (1.4)")
    func perAppIdentitySeparation() async throws {
        let host = makeHost()
        // Same physical phone: same device ID, but BETA and INTERNAL have
        // their own keypairs and grants, so they are unrelated peers.
        let (beta, betaGrant) = try mintedIdentity(app: "dev.cmux.beta")
        let (internalApp, internalGrant) = try mintedIdentity(app: "dev.cmux.internal")

        let (betaClient, betaHostEnd) = LoopbackWire().makeEnds()
        async let betaServe: Void = host.serve(connection: betaHostEnd, now: now)
        let betaOutcome = try await TransportClient.connect(
            connection: betaClient, identity: beta, grant: betaGrant)
        #expect(betaOutcome == .admitted(sessionID: "s1"))
        await betaServe

        let (internalClient, internalHostEnd) = LoopbackWire().makeEnds()
        async let internalServe: Void = host.serve(connection: internalHostEnd, now: now)
        let internalOutcome = try await TransportClient.connect(
            connection: internalClient, identity: internalApp, grant: internalGrant)
        #expect(internalOutcome == .admitted(sessionID: "s2"))
        await internalServe

        // Both sessions live side by side.
        #expect(await betaClient.isClosed == false)
        #expect(await internalClient.isClosed == false)
        #expect(await host.counters.closesByCode["superseded"] == nil)

        // And one app presenting the OTHER app's grant is denied (1.4, 3.2).
        let (crossClient, crossHostEnd) = LoopbackWire().makeEnds()
        async let crossServe: Void = host.serve(connection: crossHostEnd, now: now)
        let crossIdentity = PeerIdentity(
            appIdentity: "dev.cmux.beta", deviceID: "phone-1",
            privateKeyData: internalApp.privateKeyData)
        let cross = try await TransportClient.connect(
            connection: crossClient, identity: crossIdentity, grant: internalGrant)
        #expect(cross == .denied(.appMismatch))
        await crossServe
    }

    @Test("A wrong protocol string is denied explicitly, never a mystery hang")
    func protocolMismatchDenied() async throws {
        let host = makeHost()
        let (identity, grant) = try mintedIdentity(app: "dev.cmux.lite")
        let (client, hostEnd) = LoopbackWire().makeEnds()
        async let serving: Void = host.serve(connection: hostEnd, now: now)

        let control = await client.lane("ctl")
        var hello = Frame.hello(identity: identity, grant: grant)
        hello.payload["protocol"] = .string("cmux/mobile/2")
        try await control.send(hello)
        #expect(await control.receive() == nil)
        #expect(
            await client.termination()
                == ConnectionTermination(code: DenialCode.protocolMismatch.rawValue))
        await serving
    }
}
