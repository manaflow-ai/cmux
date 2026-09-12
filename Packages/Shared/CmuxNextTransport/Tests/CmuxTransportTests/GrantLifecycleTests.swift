import Foundation
import Testing

@testable import CmuxNextTransport

/// Integration tests for grant expiry occurring MID APP USAGE (contract 3.6,
/// Aziz's no-flurry condition, 08-19). Time is injected, so every scenario is
/// deterministic: "the app is in use" is live echo traffic across the expiry
/// moment.
@Suite("Grant expiry mid-usage (contract 3.6)")
struct GrantLifecycleTests {
    let signer = GrantSigner()
    let now: Int64 = 1_000_000

    private func makeHost(grace: Int64, warning: Int64) -> TransportHost {
        let fixedNow = now
        return TransportHost(
            verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData),
            expiryGraceSeconds: grace, expiryWarningSeconds: warning,
            epochNow: { fixedNow })
    }

    private func mint(
        for identity: PeerIdentity, grantID: String, expiresAt: Int64?
    ) throws -> PairingGrant {
        try signer.mint(
            accountID: "acct-1", deviceID: identity.deviceID,
            devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
            grantID: grantID, issuedAt: now, expiresAt: expiresAt)
    }

    private func echoRoundTrips(
        _ connection: LoopbackConnectionEnd, count: Int, from seq: Int64
    ) async throws {
        let echo = await connection.lane(TransportHost.echoLaneName)
        var validator = TrafficValidator()
        for offset in 0..<count {
            try await echo.send(
                TerminalTraffic().chunk(seq: seq + Int64(offset), size: 256, seed: 9))
            if let reply = await echo.receive() {
                validator.ingest(reply)
            }
        }
        #expect(validator.received == count)
        #expect(validator.checksumFailures == 0)
    }

    @Test("Expiry mid-usage with renewal: warning, in-session swap, ZERO closes")
    func renewalMidUsageCausesNoDisruption() async throws {
        // Grant expires at now+500; warning window 200, grace 1000.
        let host = makeHost(grace: 1_000, warning: 200)
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: identity, grantID: "g-1", expiresAt: now + 500)

        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: identity.publicKeyData)
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        let outcome = try await TransportClient().connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))
        await serving

        // The app is in use: traffic flows.
        try await echoRoundTrips(client, count: 20, from: 0)

        // Clock enters the warning window. The session must be untouched.
        await host.enforceExpiries(now: now + 400)
        try await echoRoundTrips(client, count: 10, from: 20)

        // Clock passes the EXPIRY MOMENT itself. Still no teardown (3.6b):
        // the session keeps working inside the grace window.
        await host.enforceExpiries(now: now + 600)
        try await echoRoundTrips(client, count: 10, from: 30)

        // The client hears exactly one warning on the control lane (3.6c).
        let control = await client.lane("ctl")
        let warning = await control.receive()
        #expect(warning?.type == FrameTypePolicy.grantExpiring)
        #expect(warning?.payload["exp"]?.intValue == now + 500)

        // In-session renewal over the live control lane: no disconnect.
        let renewed = try mint(for: identity, grantID: "g-2", expiresAt: now + 100_000)
        try await control.send(Frame.grantUpdate(renewed))
        let ack = await control.receive()
        #expect(ack?.type == FrameTypePolicy.grantAck)
        #expect(ack?.payload["ok"]?.boolValue == true)

        // Long past the OLD grant's expiry + grace: the renewed session lives.
        await host.enforceExpiries(now: now + 5_000)
        try await echoRoundTrips(client, count: 10, from: 40)

        // The no-flurry proof: zero closes, zero denials, one renewal, and
        // the wire never dropped, so no reconnect could ever have been needed.
        #expect(await client.isClosed == false)
        let counters = await host.counters
        #expect(counters.closesByCode.isEmpty)
        #expect(counters.denialsByCode.isEmpty)
        #expect(counters.grantRenewals == 1)
        #expect(counters.admissions == 1)  // still the ORIGINAL admission
    }

    @Test("Expiry mid-usage without renewal: ONE attributed close after grace, then denied until renewed")
    func unrenewedExpiryClosesExactlyOnce() async throws {
        let host = makeHost(grace: 1_000, warning: 200)
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: identity, grantID: "g-1", expiresAt: now + 500)

        let (client, hostEnd) = LoopbackWire().makeEnds()
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        let outcome = try await TransportClient().connect(
            connection: client, identity: identity, grant: grant)
        #expect(outcome == .admitted(sessionID: "s1"))
        await serving

        // In use across the expiry moment: expired-but-in-grace still works.
        try await echoRoundTrips(client, count: 10, from: 0)
        await host.enforceExpiries(now: now + 600)
        #expect(await client.isClosed == false)
        try await echoRoundTrips(client, count: 10, from: 10)

        // Grace lapses. Repeated enforcement must still close exactly once.
        await host.enforceExpiries(now: now + 1_600)
        await host.enforceExpiries(now: now + 1_700)
        await host.enforceExpiries(now: now + 1_800)
        #expect(await client.isClosed)
        #expect(await host.counters.closesByCode["grant-expired"] == 1)

        // The client's control lane tells the whole story: one warning, then
        // end of stream, with the attributed reason in the termination
        // itself (v7). One close, no storm.
        let control = await client.lane("ctl")
        #expect(await control.receive()?.type == FrameTypePolicy.grantExpiring)
        #expect(await control.receive() == nil)
        #expect(await client.termination() == ConnectionTermination(code: "grant-expired"))

        // Reconnecting with the same expired grant: explicit denial (3.6a).
        let (retryClient, retryHostEnd) = LoopbackWire().makeEnds()
        async let retryServe: Void = host.serve(connection: retryHostEnd, now: now + 2_000)
        let retry = try await TransportClient().connect(
            connection: retryClient, identity: identity, grant: grant)
        #expect(retry == .denied(.expired))
        await retryServe

        // A renewed grant restores service.
        let renewed = try mint(for: identity, grantID: "g-2", expiresAt: now + 100_000)
        let (freshClient, freshHostEnd) = LoopbackWire().makeEnds()
        async let freshServe: Void = host.serve(connection: freshHostEnd, now: now + 2_000)
        let fresh = try await TransportClient().connect(
            connection: freshClient, identity: identity, grant: renewed)
        #expect(fresh == .admitted(sessionID: "s2"))
        await freshServe
    }

    @Test("A rejected renewal keeps the session alive until grace lapses (3.6d)")
    func rejectedRenewalDoesNotKillTheSession() async throws {
        let host = makeHost(grace: 1_000, warning: 200)
        let identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let grant = try mint(for: identity, grantID: "g-1", expiresAt: now + 500)

        let (client, hostEnd) = LoopbackWire().makeEnds()
        async let serving: Void = host.serve(connection: hostEnd, now: now)
        _ = try await TransportClient().connect(connection: client, identity: identity, grant: grant)
        await serving

        // A renewal minted for a DIFFERENT device is rejected with a readable
        // code, and the session stays up on the old grant.
        let other = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-2")
        let wrong = try signer.mint(
            accountID: "acct-1", deviceID: other.deviceID,
            devicePublicKey: other.publicKeyData, appIdentity: other.appIdentity,
            grantID: "g-x", issuedAt: now, expiresAt: now + 100_000)
        let control = await client.lane("ctl")
        try await control.send(Frame.grantUpdate(wrong))
        let ack = await control.receive()
        #expect(ack?.payload["ok"]?.boolValue == false)
        #expect(ack?.payload["code"]?.stringValue == DenialCode.keyMismatch.rawValue)

        try await echoRoundTrips(client, count: 5, from: 0)
        #expect(await client.isClosed == false)
        #expect(await host.counters.grantRenewalRejections == 1)
    }

    @Test("A renewal cannot be expired from a stale multi-session snapshot")
    func renewalDuringAnotherExpiryCloseKeepsSessionAlive() async throws {
        let host = makeHost(grace: 1, warning: 0)
        let gate = ExpiryCloseGate()
        let firstIdentity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-1")
        let secondIdentity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "phone-2")
        let firstGrant = try mint(for: firstIdentity, grantID: "g-1", expiresAt: now + 100)
        let secondGrant = try mint(for: secondIdentity, grantID: "g-2", expiresAt: now + 100)

        let firstWire = LoopbackWire().makeEnds(
            authenticatedClientKey: firstIdentity.publicKeyData)
        let firstHost = ExpiryGatedConnection(
            base: firstWire.host, id: firstIdentity.deviceID, gate: gate)
        async let firstServing: Void = host.serve(connection: firstHost, now: now)
        let firstOutcome = try await TransportClient().connect(
            connection: firstWire.client, identity: firstIdentity, grant: firstGrant)
        #expect(firstOutcome == .admitted(sessionID: "s1"))
        await firstServing

        let secondWire = LoopbackWire().makeEnds(
            authenticatedClientKey: secondIdentity.publicKeyData)
        let secondHost = ExpiryGatedConnection(
            base: secondWire.host, id: secondIdentity.deviceID, gate: gate)
        async let secondServing: Void = host.serve(connection: secondHost, now: now)
        let secondOutcome = try await TransportClient().connect(
            connection: secondWire.client, identity: secondIdentity, grant: secondGrant)
        #expect(secondOutcome == .admitted(sessionID: "s2"))
        await secondServing

        let enforcing = Task { await host.enforceExpiries(now: now + 102) }
        let closedID = await gate.waitForFirstClose()
        let renewedIdentity: PeerIdentity
        let renewedClient: LoopbackConnectionEnd
        if closedID == firstIdentity.deviceID {
            renewedIdentity = secondIdentity
            renewedClient = secondWire.client
        } else {
            renewedIdentity = firstIdentity
            renewedClient = firstWire.client
        }

        let renewed = try mint(
            for: renewedIdentity, grantID: "renewed", expiresAt: now + 100_000)
        let control = await renewedClient.lane("ctl")
        try await control.send(Frame.grantUpdate(renewed))
        let acknowledgement = await control.receive()
        #expect(acknowledgement?.type == FrameTypePolicy.grantAck)
        #expect(acknowledgement?.payload["ok"]?.boolValue == true)

        await gate.release()
        await enforcing.value

        let key = TransportHost.SessionKey(
            deviceID: renewedIdentity.deviceID, appIdentity: renewedIdentity.appIdentity)
        #expect(await renewedClient.isClosed == false)
        #expect(await host.session(for: key)?.grant == renewed)
        #expect(await host.counters.closesByCode[CloseReason.grantExpired.code] == 1)
    }
}

/// Async gate used only to hold one real close await open while another
/// session renews. Its actor-owned streams avoid polling and preserve the
/// actor reentrancy that exposed the stale snapshot bug.
private actor ExpiryCloseGate {
    private let enteredStream: AsyncStream<String>
    private let enteredContinuation: AsyncStream<String>.Continuation
    private let releaseStream: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation
    private var blocked = true

    init() {
        let entered = AsyncStream<String>.makeStream()
        enteredStream = entered.stream
        enteredContinuation = entered.continuation
        let release = AsyncStream<Void>.makeStream()
        releaseStream = release.stream
        releaseContinuation = release.continuation
    }

    func waitIfBlocked(id: String) async {
        guard blocked else { return }
        enteredContinuation.yield(id)
        for await _ in releaseStream { break }
    }

    func waitForFirstClose() async -> String {
        for await id in enteredStream { return id }
        fatalError("expiry close gate ended before a close")
    }

    func release() {
        blocked = false
        releaseContinuation.yield(())
    }
}

/// The wrapper is safe to send because its immutable connection and actor gate
/// are Sendable; all mutable gate state remains isolated in ``ExpiryCloseGate``.
private final class ExpiryGatedConnection: PeerConnection, @unchecked Sendable {
    let base: LoopbackConnectionEnd
    let id: String
    let gate: ExpiryCloseGate

    init(base: LoopbackConnectionEnd, id: String, gate: ExpiryCloseGate) {
        self.base = base
        self.id = id
        self.gate = gate
    }

    var authenticatedRemoteKey: Data? { base.authenticatedRemoteKey }

    func lane(_ name: String) async -> any TransportLane {
        await base.lane(name)
    }

    func closeAll(reason: ConnectionTermination?) async {
        if reason?.code == CloseReason.grantExpired.code {
            await gate.waitIfBlocked(id: id)
        }
        await base.closeAll(reason: reason)
    }

    func termination() async -> ConnectionTermination? {
        await base.termination()
    }

    func terminationAfterLaneEOF() async -> ConnectionTermination? {
        await base.terminationAfterLaneEOF()
    }

    var isClosed: Bool {
        get async { await base.isClosed }
    }
}
