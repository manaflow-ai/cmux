import Foundation
import Testing

@testable import CmuxNextTransport

/// The reconnect owner against the quantified field pathologies (P2): the
/// supersede storm, the churn-while-connected loop, recovery after eviction,
/// and denial storms, all replayed at the RUNTIME level over the loopback
/// substrate with real dials.
@Suite("Reconnect owner (contract 4.3, 4.6)")
struct ReconnectOwnerTests {
    final class Rig: Sendable {
        let signer = GrantSigner()
        let host: TransportHost
        let identity: PeerIdentity
        let grant: PairingGrant
        let now: Int64 = 1_000_000

        init() throws {
            host = TransportHost(
                verifier: GrantVerifier(serverPublicKeyData: signer.publicKeyData))
            identity = PeerIdentity.generate(appIdentity: "dev.cmux.lite", deviceID: "ro-1")
            grant = try signer.mint(
                accountID: "a", deviceID: identity.deviceID,
                devicePublicKey: identity.publicKeyData, appIdentity: identity.appIdentity,
                grantID: "g-ro", issuedAt: now)
        }

        /// One real loopback dial: fresh wire, host serves it, client connects.
        func connectOnce() async throws -> ConnectAttemptResult {
            let (client, hostEnd) = LoopbackWire().makeEnds(
                authenticatedClientKey: identity.publicKeyData)
            async let serving: Void = host.serve(connection: hostEnd, now: now)
            let outcome = try await TransportClient.connect(
                connection: client, identity: identity, grant: grant)
            await serving
            switch outcome {
            case .admitted(let sessionID):
                return .admitted(client, sessionID: sessionID)
            case .denied(let code):
                return .denied(code)
            }
        }
    }

    private func waitFor(
        _ owner: ReconnectOwner, _ accept: @escaping (SessionState) -> Bool
    ) async {
        for await state in await owner.states() where accept(state) { return }
    }

    @Test("The supersede storm joins: 10 automatic triggers, exactly one dial")
    func stormOfAutomaticTriggersJoins() async throws {
        let rig = try Rig()
        let gate = FramePipe(capacity: 1)  // reused as a simple async latch
        let owner = ReconnectOwner { [rig] in
            _ = await gate.receive()  // hold every dial until released
            return try await rig.connectOnce()
        }
        await owner.endpointReady(true)
        // Field storm: foreground + push + event-stream-ended + timers, all
        // racing while one dial is in flight.
        for i in 0..<10 {
            await owner.trigger(.automatic(trigger: "storm-\(i)"))
        }
        #expect(await owner.dialsStarted == 1)
        try await gate.send(Frame(type: "go"))
        await waitFor(owner) { $0 == .ready }
        #expect(await owner.dialsStarted == 1)
        #expect(await owner.admissions == 1)
        #expect(await rig.host.counters.admissions == 1)
    }

    @Test("Eviction auto-recovers: fault-kill leads to a fresh admission, no user action")
    func autoRecoveryAfterEviction() async throws {
        let rig = try Rig()
        let owner = ReconnectOwner(
            config: .init(initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(50))
        ) { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        await waitFor(owner) { $0 == .ready }

        // The Mac abruptly evicts the session (the app-killed-my-process
        // class of field failure). Watch the stream for down-then-up so the
        // immediate replay of the stale ready state can't fool the wait.
        let stream = await owner.states()
        _ = await rig.host.killSession(
            deviceID: rig.identity.deviceID, appIdentity: rig.identity.appIdentity)
        var sawDown = false
        for await state in stream {
            if state != .ready { sawDown = true }
            if sawDown && state == .ready { break }
        }
        #expect(await owner.admissions == 2)
        #expect(await rig.host.counters.closesByCode["fault-injected"] == 1)
    }

    @Test("Denials are terminal: no automatic retry storm against a 'no'")
    func denialDoesNotRetry() async throws {
        let rig = try Rig()
        await rig.host.revokeGrant(id: "g-ro")
        let owner = ReconnectOwner(
            config: .init(initialBackoff: .milliseconds(5), maxBackoff: .milliseconds(20))
        ) { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        await waitFor(owner) { $0 == .closed(CloseReason(origin: .remote, code: "revoked")) }
        // Give any (wrong) retry machinery ample chances to fire.
        for _ in 0..<200 { await Task.yield() }
        #expect(await owner.dialsStarted == 1)
        #expect(await rig.host.counters.denialsByCode["revoked"] == 1)
    }

    @Test("Transport failures back off, then succeed; success resets the ladder")
    func backoffThenSuccess() async throws {
        let rig = try Rig()
        let failures = FramePipe(capacity: 8)
        for seq in Int64(0)..<3 {
            try await failures.send(Frame(type: "fail", payload: ["seq": .int(seq)]))
        }
        await failures.close()  // drained pipe then returns nil = stop failing
        let owner = ReconnectOwner(
            config: .init(initialBackoff: .milliseconds(2), maxBackoff: .milliseconds(20))
        ) { [rig] in
            if await failures.receive() != nil {
                throw TransportError.pipeClosed  // synthetic network failure
            }
            return try await rig.connectOnce()
        }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        await waitFor(owner) { $0 == .ready }
        #expect(await owner.dialsStarted == 4)  // 3 failures + 1 success
        #expect(await owner.admissions == 1)
    }

    @Test("Supersession does not redial: the newer device keeps the session")
    func supersededStaysDown() async throws {
        let rig = try Rig()
        let owner = ReconnectOwner { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        await waitFor(owner) { $0 == .ready }

        // A second connection with the SAME identity (relaunched app,
        // another process) takes over; the owner must yield, not fight.
        _ = try await rig.connectOnce()
        await waitFor(owner) {
            $0 == .closed(CloseReason(origin: .remote, code: "superseded"))
        }
        for _ in 0..<200 { await Task.yield() }
        #expect(await owner.dialsStarted == 1)
        #expect(await rig.host.counters.closesByCode["superseded"] == 1)
    }
}
