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

/// Models a silent peer (half-open QUIC): a local closeAll never reaches the
/// remote, so the host keeps seeing live lanes. Used to prove the owner's own
/// tasks die on stop() even when the wire cannot deliver the close.
final class HalfOpenConnection: PeerConnection {
    private let inner: LoopbackConnectionEnd

    init(_ inner: LoopbackConnectionEnd) { self.inner = inner }

    var authenticatedRemoteKey: Data? {
        inner.authenticatedRemoteKey
    }

    func lane(_ name: String) async -> any TransportLane {
        await inner.lane(name)
    }

    func closeAll(reason: ConnectionTermination?) async {}  // never lands

    func termination() async -> ConnectionTermination? {
        await inner.termination()
    }

    var isClosed: Bool {
        get async { await inner.isClosed }
    }
}

/// Collects frames surfaced through `onControlFrame`.
actor ControlFrameCollector {
    private(set) var frames: [Frame] = []

    func append(_ frame: Frame) { frames.append(frame) }

    var count: Int { frames.count }
}

/// Shutdown regressions: a stopped owner must be DONE — no surviving backoff
/// timer, no dialable .closed state, no watch loop left consuming a ctl lane.
@Suite("Reconnect owner shutdown (contract 4.3: stop is final)")
struct ReconnectOwnerShutdownTests {
    private func waitFor(
        _ owner: ReconnectOwner, _ accept: @escaping (SessionState) -> Bool
    ) async {
        for await state in await owner.states() where accept(state) { return }
    }

    @Test("stop() during backoff cancels the scheduled redial: no dial after shutdown")
    func stopDuringBackoffNeverRedials() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let failures = FramePipe(capacity: 1)
        try await failures.send(Frame(type: "fail"))
        await failures.close()  // drained pipe then returns nil = stop failing
        let owner = ReconnectOwner(
            config: .init(initialBackoff: .milliseconds(40), maxBackoff: .milliseconds(40))
        ) { [rig] in
            if await failures.receive() != nil {
                throw TransportError.pipeClosed  // synthetic network failure
            }
            return try await rig.connectOnce()
        }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        // The dial failed; the owner is idle inside its 40ms backoff window.
        await waitFor(owner) { $0 == .idle }
        await owner.stop()
        // Long past the backoff wake-up: the scheduled redial must be dead,
        // not dialing a fresh connection after shutdown.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await owner.dialsStarted == 1)
        #expect(await owner.state == .closed(.userRequested))
        #expect(await owner.currentConnection == nil)
        #expect(await rig.host.counters.admissions == 0)
    }

    @Test("A stopped owner refuses every later trigger: .closed by stop() is terminal")
    func closedOwnerRefusesLaterTriggers() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let owner = ReconnectOwner { [rig] in try await rig.connectOnce() }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        await waitFor(owner) { $0 == .ready }
        await owner.stop()
        await waitFor(owner) { $0.isClosed }

        // Foreground, push, timer, even a user tap: the owner was told to
        // stop, so nothing may dial it back up.
        await owner.trigger(.automatic(trigger: "foreground"))
        await owner.trigger(.explicit(trigger: "tap"))
        for _ in 0..<200 { await Task.yield() }
        #expect(await owner.dialsStarted == 1)
        #expect(await owner.admissions == 1)
        #expect(await owner.state == .closed(.userRequested))
        #expect(await owner.currentConnection == nil)
    }
}

extension ReconnectOwnerShutdownTests {
    /// One loopback dial whose admitted connection is half-open: the client
    /// side's closeAll never reaches the wire.
    private func connectOnceHalfOpen(
        _ rig: ReconnectOwnerTests.Rig
    ) async throws -> ConnectAttemptResult {
        let (client, hostEnd) = LoopbackWire().makeEnds(
            authenticatedClientKey: rig.identity.publicKeyData)
        async let serving: Void = rig.host.serve(connection: hostEnd, now: rig.now)
        let outcome = try await TransportClient.connect(
            connection: client, identity: rig.identity, grant: rig.grant)
        await serving
        switch outcome {
        case .admitted(let sessionID):
            return .admitted(HalfOpenConnection(client), sessionID: sessionID)
        case .denied(let code):
            return .denied(code)
        }
    }

    @Test("stop() cancels the ctl watch loop even on a half-open connection")
    func stopCancelsWatchLoopOnHalfOpenConnection() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let collector = ControlFrameCollector()
        let owner = ReconnectOwner(
            connectOnce: { [rig] in try await self.connectOnceHalfOpen(rig) },
            onControlFrame: { await collector.append($0) })
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        await waitFor(owner) { $0 == .ready }

        // The surface path is live: a pushed credential reaches the consumer.
        #expect(
            await rig.host.pushRelayCredential(
                deviceID: rig.identity.deviceID, appIdentity: rig.identity.appIdentity,
                url: "https://relay-1.example", token: "tok-1"))
        var spins = 0
        while await collector.count < 1, spins < 2_000 {
            spins += 1
            await Task.yield()
        }
        #expect(await collector.count == 1)

        await owner.stop()
        // The peer is half-open: the owner's close never reached the wire, so
        // the host still sees a live session and pushes again. A stopped
        // owner's watch loop must be gone — nothing may surface (or silently
        // consume) frames after shutdown.
        #expect(
            await rig.host.pushRelayCredential(
                deviceID: rig.identity.deviceID, appIdentity: rig.identity.appIdentity,
                url: "https://relay-2.example", token: "tok-2"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await collector.count == 1)
    }

    @Test("An explicit redial's losing attempt never leaves an orphaned live connection")
    func replacedAttemptConnectionIsClosed() async throws {
        let rig = try ReconnectOwnerTests.Rig()
        let gate = FramePipe(capacity: 4)  // holds the first admitted dial
        let admitted = AdmittedConnections()
        let owner = ReconnectOwner { [rig] in
            let result = try await rig.connectOnce()
            if case .admitted(let conn, _) = result { await admitted.add(conn) }
            if await admitted.count == 1 {
                _ = await gate.receive()  // parks; resumes nil on cancellation
            }
            return result
        }
        await owner.endpointReady(true)
        await owner.trigger(.automatic(trigger: "launch"))
        var spins = 0
        while await admitted.count < 1, spins < 5_000 {
            spins += 1
            await Task.yield()
        }
        // A user retry replaces the in-flight attempt; the replaced attempt
        // then completes holding an already-admitted connection. That
        // connection must be closed, never adopted and never orphaned.
        await owner.trigger(.explicit(trigger: "manual-retry"))
        await waitFor(owner) { $0 == .ready }
        try? await gate.send(Frame(type: "go"))
        let stale = try #require(await admitted.first)
        spins = 0
        while await stale.isClosed == false, spins < 5_000 {
            spins += 1
            await Task.yield()
        }
        #expect(await stale.isClosed)
        let current = try #require(await owner.currentConnection)
        #expect(current !== stale)
        #expect(await current.isClosed == false)
        #expect(await owner.admissions == 1)
        // Exactly one live session on the host, owned by the winning dial.
        _ = await rig.host.reapClosedSessions()
        #expect(await rig.host.sessionCount == 1)
    }
}

/// Records every connection a dialer closure was admitted with.
actor AdmittedConnections {
    private(set) var conns: [any PeerConnection] = []

    func add(_ conn: any PeerConnection) { conns.append(conn) }

    var count: Int { conns.count }

    var first: (any PeerConnection)? { conns.first }
}
