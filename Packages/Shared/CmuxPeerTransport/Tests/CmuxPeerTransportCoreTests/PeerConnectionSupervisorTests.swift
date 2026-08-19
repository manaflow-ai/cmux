import Foundation
import Testing

@testable import CmuxPeerTransportCore

/// Controllable session: the test decides when and why it closes.
private final class FakeSession: PeerSessionHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var closeReason: PeerSessionCloseReason?
    private var waiters: [CheckedContinuation<PeerSessionCloseReason, Never>] = []
    private(set) var localCloseCount = 0

    func awaitClose() async -> PeerSessionCloseReason {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let closeReason {
                lock.unlock()
                continuation.resume(returning: closeReason)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func close(reason: String) async {
        finish(reason: .local(reason), countsAsLocal: true)
    }

    func remoteClose(reason: String) {
        finish(reason: .remote(reason), countsAsLocal: false)
    }

    private func finish(reason: PeerSessionCloseReason, countsAsLocal: Bool) {
        lock.lock()
        if countsAsLocal { localCloseCount += 1 }
        guard closeReason == nil else {
            lock.unlock()
            return
        }
        closeReason = reason
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resumed {
            waiter.resume(returning: reason)
        }
    }
}

/// Scriptable establisher: each dial pulls the next scripted outcome; when the
/// script is empty the dial parks until the test resolves it.
private actor FakeEstablisher: PeerSessionEstablishing {
    enum Outcome {
        case succeed(FakeSession)
        case fail(PeerDialFailure)
        case park
    }

    private(set) var establishCount = 0
    private(set) var contexts: [PeerDialContext] = []
    private var script: [Outcome] = []
    private var parked: [CheckedContinuation<FakeSession, any Error>] = []

    func enqueue(_ outcome: Outcome) {
        script.append(outcome)
    }

    func resolveParked(with session: FakeSession) {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume(returning: session)
    }

    func failParked(with failure: PeerDialFailure) {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume(throwing: failure)
    }

    var parkedCount: Int {
        parked.count
    }

    func establish(context: PeerDialContext) async throws -> any PeerSessionHandle {
        establishCount += 1
        contexts.append(context)
        let outcome: Outcome = script.isEmpty ? .park : script.removeFirst()
        switch outcome {
        case .succeed(let session):
            return session
        case .fail(let failure):
            throw failure
        case .park:
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    parked.append(continuation)
                }
            } onCancel: {
                Task { await self.cancelAllParked() }
            }
        }
    }

    private func cancelAllParked() {
        let resumed = parked
        parked.removeAll()
        for continuation in resumed {
            continuation.resume(throwing: CancellationError())
        }
    }
}

private enum SupervisorHarness {
    static let fastProfile = PeerReconnectBackoff.Profile(
        floor: .milliseconds(10),
        cap: .milliseconds(40)
    )

    static func make(
        establisher: FakeEstablisher
    ) -> PeerConnectionSupervisor {
        PeerConnectionSupervisor(
            establisher: establisher,
            backoffProfile: fastProfile,
            backoffSeed: 1
        )
    }

    static func waitUntil(
        timeoutMilliseconds: Int64 = 2_000,
        _ condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        while clock.now < deadline {
            if await condition() { return true }
            try? await clock.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

@Suite struct PeerConnectionSupervisorTests {
    @Test func automaticTriggerJoinsInFlightAttemptInsteadOfSuperseding() async {
        let establisher = FakeEstablisher()
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await establisher.parkedCount == 1 }

        // The storm: presence + foreground + network change while dialing.
        await supervisor.note(trigger: .presencePush)
        await supervisor.note(trigger: .foreground)
        await supervisor.note(trigger: .networkPathChanged)

        let session = FakeSession()
        await establisher.resolveParked(with: session)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }

        #expect(await establisher.establishCount == 1)
        #expect(await supervisor.state == .ready)
    }

    @Test func explicitTriggerReplacesInFlightAttempt() async {
        let establisher = FakeEstablisher()
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await establisher.parkedCount == 1 }

        await supervisor.note(trigger: .manualRetry)
        _ = await SupervisorHarness.waitUntil { await establisher.establishCount == 2 }

        let session = FakeSession()
        await establisher.resolveParked(with: session)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }

        #expect(await establisher.establishCount == 2)
    }

    @Test func automaticTriggerWhileReadyIsSatisfiedByTheLiveSession() async {
        let establisher = FakeEstablisher()
        let session = FakeSession()
        await establisher.enqueue(.succeed(session))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }

        await supervisor.note(trigger: .foreground)
        await supervisor.note(trigger: .presencePush)
        await supervisor.note(trigger: .networkPathChanged)
        try? await ContinuousClock().sleep(for: .milliseconds(60))

        #expect(await establisher.establishCount == 1)
        #expect(await supervisor.state == .ready)
        #expect(session.localCloseCount == 0)
    }

    @Test func connectionMethodChangeRedialsEvenWhileReady() async {
        let establisher = FakeEstablisher()
        let first = FakeSession()
        let second = FakeSession()
        await establisher.enqueue(.succeed(first))
        await establisher.enqueue(.succeed(second))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }

        await supervisor.note(trigger: .connectionMethodChanged)
        _ = await SupervisorHarness.waitUntil { await establisher.establishCount == 2 }
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }

        #expect(first.localCloseCount == 1)
        #expect(await establisher.establishCount == 2)
    }

    @Test func failureArmsLadderAndBackoffExpiryRedials() async {
        let establisher = FakeEstablisher()
        await establisher.enqueue(
            .fail(PeerDialFailure(classification: .unreachable, reason: "timeout"))
        )
        let session = FakeSession()
        await establisher.enqueue(.succeed(session))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        let recovered = await SupervisorHarness.waitUntil {
            await supervisor.state == .ready
        }

        #expect(recovered)
        #expect(await establisher.establishCount == 2)
    }

    @Test func successStopsTheRetryLadder() async {
        let establisher = FakeEstablisher()
        let session = FakeSession()
        await establisher.enqueue(
            .fail(PeerDialFailure(classification: .transient, reason: "blip"))
        )
        await establisher.enqueue(.succeed(session))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }
        let countAtReady = await establisher.establishCount

        // Longer than several ladder periods: no further dials may happen.
        try? await ContinuousClock().sleep(for: .milliseconds(200))
        #expect(await establisher.establishCount == countAtReady)
        #expect(await supervisor.state == .ready)
    }

    @Test func authorizationDenialIsStickyAgainstAutomaticTriggers() async {
        let establisher = FakeEstablisher()
        await establisher.enqueue(
            .fail(PeerDialFailure(classification: .authorizationDenied, reason: "revoked"))
        )
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil {
            if case .denied = await supervisor.state { return true }
            return false
        }

        await supervisor.note(trigger: .foreground)
        await supervisor.note(trigger: .networkPathChanged)
        await supervisor.note(trigger: .presencePush)
        try? await ContinuousClock().sleep(for: .milliseconds(100))

        #expect(await establisher.establishCount == 1)

        // Explicit intent breaks the stickiness.
        let session = FakeSession()
        await establisher.enqueue(.succeed(session))
        await supervisor.note(trigger: .manualRetry)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }
        #expect(await establisher.establishCount == 2)
    }

    @Test func authorizationRestoredClearsDenialAndRedials() async {
        let establisher = FakeEstablisher()
        await establisher.enqueue(
            .fail(PeerDialFailure(classification: .authorizationDenied, reason: "revoked"))
        )
        let session = FakeSession()
        await establisher.enqueue(.succeed(session))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil {
            if case .denied = await supervisor.state { return true }
            return false
        }

        await supervisor.noteAuthorizationRestored()
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }
        #expect(await establisher.establishCount == 2)
    }

    @Test func inactiveSceneParksAutomaticTriggersAndReplaysNewestOnce() async {
        let establisher = FakeEstablisher()
        let session = FakeSession()
        await establisher.enqueue(.succeed(session))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.noteScenePhase(active: false)
        await supervisor.note(trigger: .networkPathChanged)
        await supervisor.note(trigger: .presencePush)
        try? await ContinuousClock().sleep(for: .milliseconds(50))
        #expect(await establisher.establishCount == 0)

        await supervisor.noteScenePhase(active: true)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }
        #expect(await establisher.establishCount == 1)
    }

    @Test func remoteCloseArmsRetryAndLocalCloseGoesIdle() async {
        let establisher = FakeEstablisher()
        let first = FakeSession()
        let second = FakeSession()
        await establisher.enqueue(.succeed(first))
        await establisher.enqueue(.succeed(second))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }

        first.remoteClose(reason: "event stream ended")
        let redialed = await SupervisorHarness.waitUntil {
            let count = await establisher.establishCount
            let state = await supervisor.state
            return count == 2 && state == .ready
        }
        #expect(redialed)
    }

    @Test func shutDownClosesSessionAndStopsRedialing() async {
        let establisher = FakeEstablisher()
        let session = FakeSession()
        await establisher.enqueue(.succeed(session))
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }

        await supervisor.shutDown(reason: "sign-out")
        #expect(session.localCloseCount == 1)
        #expect(await supervisor.state == .idle)

        try? await ContinuousClock().sleep(for: .milliseconds(100))
        #expect(await establisher.establishCount == 1)
    }

    @Test func supersededEstablishmentResultIsClosedNotAdopted() async {
        let establisher = FakeEstablisher()
        let supervisor = SupervisorHarness.make(establisher: establisher)

        await supervisor.note(trigger: .launch)
        _ = await SupervisorHarness.waitUntil { await establisher.parkedCount == 1 }

        // Explicit replacement cancels the parked attempt; its session (if it
        // resolved late) must never become the adopted session.
        await supervisor.note(trigger: .manualRetry)
        _ = await SupervisorHarness.waitUntil { await establisher.establishCount == 2 }

        let winner = FakeSession()
        await establisher.resolveParked(with: winner)
        _ = await SupervisorHarness.waitUntil { await supervisor.state == .ready }
        #expect(await supervisor.state == .ready)
    }
}
