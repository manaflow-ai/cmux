import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxIrohTransport

struct CmxConnectivityPeerSessionTests {
    @Test
    func concurrentCallersShareOneDialAndOneAdmittedSession() async throws {
        let request = try Self.request()
        let routeVariant = try Self.request(routeID: "iroh-v2-refreshed")
        let peerID = try CmxConnectivityPeerID(request: request)
        let admitted = TestConnectivitySession(continuityID: 7)
        let builder = GatedConnectivitySessionBuilder(session: admitted)
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        let first = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        let second = Task { try await peer.connectedSession(for: routeVariant) }
        await builder.release()

        _ = try await first.value
        _ = try await second.value

        #expect(await builder.callCount() == 1)
        #expect(await peer.snapshot().phase == .connected)
        #expect(await peer.snapshot().connectionGeneration == 1)
    }

    @Test
    func nextControlOwnerWaitsAndReleaseClosesThePeerConnection() async throws {
        let request = try Self.request()
        let routeVariant = try Self.request(routeID: "iroh-v2-refreshed")
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(continuityID: 11)
        let secondSession = TestConnectivitySession(continuityID: 12)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession, secondSession]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let firstOwner = UUID()
        let secondOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        let secondAcquire = Task {
            try await peer.acquireControl(for: routeVariant, ownerID: secondOwner)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
            #expect(await builder.callCount() == 1)
        }
        await peer.releaseControl(ownerID: firstOwner)

        #expect(await firstSession.closeCount() == 1)
        _ = try await secondAcquire.value
        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 12)
        await peer.updateControlPurpose(
            ownerID: secondOwner,
            purpose: .backgroundControl
        )
        #expect(await peer.snapshot().controlPurpose == .backgroundControl)
        await peer.releaseControl(ownerID: firstOwner)
        #expect(await secondSession.closeCount() == 0)
        await peer.releaseControl(ownerID: secondOwner)
    }

    @Test
    func replacementWaitsForParentCloseAcknowledgement() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(
            continuityID: 15,
            gatesFirstClose: true
        )
        let replacement = TestConnectivitySession(continuityID: 16)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession, replacement]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let firstOwner = UUID()
        let replacementOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        let release = Task {
            await peer.releaseControl(ownerID: firstOwner)
        }
        try await Self.waitUntil { await firstSession.closeGateIsWaiting() }
        let acquireReplacement = Task {
            try await peer.acquireControl(
                for: request,
                ownerID: replacementOwner
            )
        }
        let replacementStartedBeforeCloseFinished: Bool
        do {
            try await Self.waitUntil { await builder.callCount() == 2 }
            replacementStartedBeforeCloseFinished = true
        } catch {
            replacementStartedBeforeCloseFinished = false
        }

        await firstSession.releaseCloseGate()
        await release.value
        _ = try await acquireReplacement.value

        #expect(!replacementStartedBeforeCloseFinished)
        #expect(await peer.connectionContinuityID() == 16)
        await peer.releaseControl(ownerID: replacementOwner)
    }

    @Test
    func replacementStartsWhileRetiredChildCleanupRemainsBlocked() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(
            continuityID: 117,
            gatesPostCloseCleanup: true
        )
        let replacement = TestConnectivitySession(continuityID: 118)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [retired, replacement]
        )
        let diagnosticLog = DiagnosticLog(capacity: 64)
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            },
            diagnosticLog: diagnosticLog
        )
        let retiredOwner = UUID()
        let replacementOwner = UUID()

        _ = try await peer.acquireControl(
            for: request,
            ownerID: retiredOwner
        )
        let replacementAcquire = Task {
            try await peer.acquireControl(
                for: request,
                ownerID: replacementOwner
            )
        }
        let release = Task {
            await peer.releaseControl(ownerID: retiredOwner)
        }

        try await Self.waitUntil {
            await retired.postCloseCleanupIsWaiting()
        }
        await release.value
        _ = try await replacementAcquire.value

        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 118)
        let lifecycleBeforeCleanup = try await Self.waitForLifecycleKinds(
            in: diagnosticLog,
            containing: [
                .retirementStarted,
                .parentCloseAcknowledged,
                .controlOwnerReleased,
                .replacementDialStarted,
            ]
        )
        let retirementIndex = try #require(
            lifecycleBeforeCleanup.firstIndex(of: .retirementStarted)
        )
        let parentCloseIndex = try #require(
            lifecycleBeforeCleanup[retirementIndex...]
                .firstIndex(of: .parentCloseAcknowledged)
        )
        let ownerReleaseIndex = try #require(
            lifecycleBeforeCleanup[parentCloseIndex...]
                .firstIndex(of: .controlOwnerReleased)
        )
        let replacementDialIndex = try #require(
            lifecycleBeforeCleanup[ownerReleaseIndex...]
                .firstIndex(of: .replacementDialStarted)
        )
        #expect(retirementIndex < parentCloseIndex)
        #expect(parentCloseIndex < ownerReleaseIndex)
        #expect(ownerReleaseIndex < replacementDialIndex)
        #expect(!lifecycleBeforeCleanup.contains(.postCloseCleanupCompleted))

        await retired.releasePostCloseCleanup()
        _ = try await Self.waitForLifecycleKinds(
            in: diagnosticLog,
            containing: [.postCloseCleanupCompleted]
        )
        await peer.releaseControl(ownerID: replacementOwner)
    }

    @Test
    func releaseDuringPendingDialInvalidatesLateResultAndUnblocksNextOwner() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(continuityID: 17)
        let replacement = TestConnectivitySession(continuityID: 18)
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [retired, replacement]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let retiredOwner = UUID()
        let replacementOwner = UUID()

        let retiredAcquire = Task {
            try await peer.acquireControl(for: request, ownerID: retiredOwner)
        }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await peer.releaseControl(ownerID: retiredOwner)

        let replacementAcquire = Task {
            try await peer.acquireControl(
                for: request,
                ownerID: replacementOwner
            )
        }
        let replacementStartedWithoutLateDial: Bool
        do {
            try await Self.waitUntil { await builder.callCount() == 2 }
            replacementStartedWithoutLateDial = true
        } catch {
            replacementStartedWithoutLateDial = false
        }

        // Let the cancelled first builder return after its generation retired.
        // It must be closed instead of installed.
        await builder.release(call: 0)
        if !replacementStartedWithoutLateDial {
            await peer.releaseControl(ownerID: retiredOwner)
            try await Self.waitUntil { await builder.callCount() == 2 }
        }
        await builder.release(call: 1)
        _ = try await replacementAcquire.value
        _ = await retiredAcquire.result

        #expect(replacementStartedWithoutLateDial)
        #expect(await retired.closeCount() == 1)
        #expect(await peer.connectionContinuityID() == 18)
        await peer.releaseControl(ownerID: replacementOwner)
    }

    @Test
    func featureLaneCannotDialWithoutAnActiveControlOwner() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [TestConnectivitySession(continuityID: 19)]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        await #expect(throws: CmxConnectivityEngineError.inactive) {
            _ = try await peer.openBidirectionalLane(
                for: request,
                lane: .artifact(
                    resourceID: CmxIrohResourceID("artifact:no-control"),
                    offset: 0
                ),
                priority: 1
            )
        }
        #expect(await builder.callCount() == 0)
    }

    @Test
    func cancelledControlWaiterCannotBlockTheNextOwner() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(continuityID: 13)
        let nextSession = TestConnectivitySession(continuityID: 14)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession, nextSession]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let firstOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        let cancelled = Task {
            try await peer.acquireControl(for: request, ownerID: UUID())
        }
        for _ in 0 ..< 100 { await Task.yield() }
        cancelled.cancel()
        if case .success = await cancelled.result {
            Issue.record("The cancelled control waiter unexpectedly acquired ownership")
        }

        let nextOwner = UUID()
        let next = Task {
            try await peer.acquireControl(for: request, ownerID: nextOwner)
        }
        for _ in 0 ..< 100 {
            await Task.yield()
            #expect(await builder.callCount() == 1)
        }
        await peer.releaseControl(ownerID: firstOwner)
        _ = try await next.value

        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 14)
        await peer.releaseControl(ownerID: nextOwner)
    }

    @Test
    func remoteClosureClearsOwnershipAndTheNextOperationRedials() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(continuityID: 21)
        let secondSession = TestConnectivitySession(continuityID: 22)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession, secondSession]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let firstOwner = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: firstOwner)
        await firstSession.finishRemotely(failure: .transportIdleTimedOut)
        try await Self.waitUntil {
            await peer.snapshot().phase == .failed
        }

        let failed = await peer.snapshot()
        #expect(failed.failure == .transportIdleTimedOut)
        #expect(!failed.controlLaneOwned)
        _ = try await peer.acquireControl(for: request, ownerID: UUID())
        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 22)
    }

    @Test
    func unavailableSelectedPathEvictsTheSessionAndTheNextOperationRedials() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let stranded = TestConnectivitySession(
            continuityID: 23,
            keepsSelectedPathStreamOpen: true
        )
        let replacement = TestConnectivitySession(continuityID: 24)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [stranded, replacement]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        _ = try await peer.acquireControl(for: request, ownerID: UUID())
        try await Self.waitUntil { await stranded.hasSelectedPathObserver() }
        await stranded.publishSelectedPath(.unavailable)
        try await Self.waitUntil { await peer.snapshot().phase == .failed }

        let failed = await peer.snapshot()
        #expect(failed.failure == .noRoute)
        #expect(!failed.controlLaneOwned)
        #expect(await stranded.closeCount() == 1)

        _ = try await peer.acquireControl(for: request, ownerID: UUID())
        #expect(await builder.callCount() == 2)
        #expect(await peer.connectionContinuityID() == 24)
    }

    @Test
    func lateClosureCleanupCannotOverwriteAReplacementSession() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let firstSession = TestConnectivitySession(
            continuityID: 71,
            gatesCloseAttribution: true
        )
        let replacement = TestConnectivitySession(continuityID: 72)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [firstSession, replacement]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let ownerID = UUID()
        let replacementOwnerID = UUID()

        _ = try await peer.acquireControl(for: request, ownerID: ownerID)
        await firstSession.finishRemotely(failure: .transportIdleTimedOut)
        try await Self.waitUntil {
            await firstSession.closeAttributionIsWaiting()
        }
        _ = try await peer.acquireControl(
            for: request,
            ownerID: replacementOwnerID
        )
        await firstSession.releaseCloseAttribution()
        for _ in 0 ..< 100 { await Task.yield() }

        let snapshot = await peer.snapshot()
        #expect(await peer.connectionContinuityID() == 72)
        #expect(snapshot.phase == .connected)
        #expect(snapshot.failure == .none)
        #expect(snapshot.controlLaneOwned)
        await peer.releaseControl(ownerID: ownerID)
        await peer.releaseControl(ownerID: replacementOwnerID)
    }

    @Test
    func concurrentCallerSharesCandidateDuringTheLivenessProbe() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let candidate = TestConnectivitySession(
            continuityID: 81,
            gatesFirstIsClosedCheck: true
        )
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [candidate]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        // Keep the first caller in the dead-on-arrival probe. The second must
        // share that candidate instead of starting a redundant physical dial.
        let firstCaller = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await builder.release(call: 0)
        try await Self.waitUntil { await candidate.isClosedGateIsWaiting() }
        let secondCaller = Task { try await peer.connectedSession(for: request) }
        _ = try await secondCaller.value
        #expect(await builder.callCount() == 1)
        await candidate.releaseIsClosedGate()
        _ = try await firstCaller.value

        #expect(await peer.connectionContinuityID() == 81)
        #expect(await candidate.closeCount() == 0)
        #expect(await peer.snapshot().phase == .connected)
        await peer.invalidate()
    }

    @Test
    func invalidationDuringCandidateProbeRequiresAFreshDial() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(
            continuityID: 91,
            gatesFirstIsClosedCheck: true,
            gatesFirstClose: true
        )
        let replacement = TestConnectivitySession(continuityID: 92)
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [retired, replacement]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildRetirableSession: { request, retirement in
                let session = try await builder.build(request)
                try await retirement.register(session)
                return session
            }
        )

        let retiredCaller = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await builder.release(call: 0)
        try await Self.waitUntil { await retired.isClosedGateIsWaiting() }
        let invalidation = Task { await peer.invalidate() }
        try await Self.waitUntil { await retired.closeGateIsWaiting() }
        await retired.releaseCloseGate()
        await invalidation.value
        await retired.releaseIsClosedGate()
        if case .success = await retiredCaller.result {
            Issue.record("The retired candidate unexpectedly installed")
        }

        let replacementCaller = Task {
            try await peer.connectedSession(for: request)
        }
        try await Self.waitUntil { await builder.callCount() == 2 }
        await builder.release(call: 1)
        let session = try await replacementCaller.value
        #expect(await session.connectionContinuityID() == 92)
        #expect(await peer.connectionContinuityID() == 92)
        #expect(await retired.closeCount() >= 1)
        await peer.invalidate()
    }

    @Test
    func deadOnArrivalSessionIsClosedAndRedialedOnce() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let dead = TestConnectivitySession(continuityID: 31)
        await dead.finishRemotely(failure: .connectionClosed)
        let live = TestConnectivitySession(continuityID: 32)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [dead, live]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        _ = try await peer.connectedSession(for: request)

        #expect(await builder.callCount() == 2)
        #expect(await dead.closeCount() == 1)
        #expect(await peer.connectionContinuityID() == 32)
        await peer.invalidate()
    }

    @Test
    func cancelledDialDoesNotBlockTheReplacementStart() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(continuityID: 41)
        let live = TestConnectivitySession(continuityID: 42)
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [retired, live]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        let first = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await peer.invalidate()
        let second = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 2 }
        await builder.release(call: 1)

        _ = try await second.value
        await builder.release(call: 0)
        if case .success = await first.result {
            Issue.record("The retired dial unexpectedly succeeded")
        }
        #expect(await retired.closeCount() == 1)
        #expect(await peer.connectionContinuityID() == 42)
        await peer.invalidate()
    }

    @Test
    func wedgedRetiredDialCannotBlockReplacement() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(continuityID: 51)
        let live = TestConnectivitySession(continuityID: 52)
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [retired, live]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        let first = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await peer.invalidate()
        let second = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 2 }
        await builder.release(call: 1)
        _ = try await second.value
        await builder.release(call: 0)
        if case .success = await first.result {
            Issue.record("The retired dial unexpectedly succeeded")
        }
        try await Self.waitUntil { await retired.closeCount() == 1 }
        #expect(await peer.connectionContinuityID() == 52)
        await peer.invalidate()
    }

    @Test
    func oneWedgedRetiredDialDoesNotTaxLaterRedials() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let retired = TestConnectivitySession(continuityID: 61)
        let second = TestConnectivitySession(continuityID: 62)
        let third = TestConnectivitySession(continuityID: 63)
        let builder = OrderedGatedConnectivitySessionBuilder(
            sessions: [retired, second, third]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )

        let firstDial = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 1 }
        await peer.invalidate()
        let secondDial = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 2 }
        await builder.release(call: 1)
        _ = try await secondDial.value
        await peer.invalidate()

        let thirdDial = Task { try await peer.connectedSession(for: request) }
        try await Self.waitUntil { await builder.callCount() == 3 }
        await builder.release(call: 2)
        _ = try await thirdDial.value

        await builder.release(call: 0)
        _ = await firstDial.result
        await peer.invalidate()
    }

    @Test
    func sessionOwnerRejectsSubstitutedPeerIntentBeforeDialing() async throws {
        let request = try Self.request()
        let peerID = try CmxConnectivityPeerID(request: request)
        let builder = SequencedConnectivitySessionBuilder(
            sessions: [TestConnectivitySession(continuityID: 1)]
        )
        let peer = CmxConnectivityPeerSession(
            peerID: peerID,
            buildSession: { request in
                try await builder.build(request)
            }
        )
        let substituted = try Self.request(
            deviceID: "223e4567-e89b-42d3-a456-426614174999"
        )

        await #expect(throws: CmxConnectivityEngineError.peerIntentMismatch) {
            _ = try await peer.connectedSession(for: substituted)
        }
        #expect(await builder.callCount() == 0)
    }

    private static func request(
        deviceID: String = "123e4567-e89b-42d3-a456-426614174999",
        routeID: String = "iroh-v2"
    ) throws -> CmxByteTransportRequest {
        let identity = try CmxIrohPeerIdentity(
            endpointID: String(repeating: "a", count: 64)
        )
        return CmxByteTransportRequest(
            route: try CmxAttachRoute(
                id: routeID,
                kind: .iroh,
                endpoint: .peer(identity: identity, pathHints: [])
            ),
            expectedPeerDeviceID: deviceID,
            authorizationMode: .transportAdmission
        )
    }

    private static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0 ..< 1_000 {
            if await condition() { return }
            await Task.yield()
        }
        struct TimedOut: Error {}
        throw TimedOut()
    }

    private static func waitForLifecycleKinds(
        in log: DiagnosticLog,
        containing requiredKinds: Set<DiagnosticSessionLifecycleKind>
    ) async throws -> [DiagnosticSessionLifecycleKind] {
        for _ in 0 ..< 1_000 {
            let observed: [DiagnosticSessionLifecycleKind] =
                await log.snapshot().events.compactMap { event in
                    guard event.code == .transportSessionLifecycle,
                          let rawValue = event.a else { return nil }
                    return DiagnosticSessionLifecycleKind(rawValue: rawValue)
                }
            if requiredKinds.isSubset(of: Set(observed)) {
                return observed
            }
            await Task.yield()
        }
        struct TimedOut: Error {}
        throw TimedOut()
    }
}

private actor GatedConnectivitySessionBuilder {
    private let session: any CmxConnectivitySession
    private var calls = 0
    private var gate: CheckedContinuation<Void, Never>?

    init(session: any CmxConnectivitySession) {
        self.session = session
    }

    func build(
        _ request: CmxByteTransportRequest
    ) async throws -> any CmxConnectivitySession {
        _ = request
        calls += 1
        await withCheckedContinuation { continuation in
            gate = continuation
        }
        return session
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func callCount() -> Int { calls }
}

private actor SequencedConnectivitySessionBuilder {
    private var sessions: [any CmxConnectivitySession]
    private var calls = 0

    init(sessions: [any CmxConnectivitySession]) {
        self.sessions = sessions
    }

    func build(
        _ request: CmxByteTransportRequest
    ) throws -> any CmxConnectivitySession {
        _ = request
        calls += 1
        return sessions.removeFirst()
    }

    func callCount() -> Int { calls }
}

private actor OrderedGatedConnectivitySessionBuilder {
    private let sessions: [any CmxConnectivitySession]
    private var calls = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]

    init(sessions: [any CmxConnectivitySession]) {
        self.sessions = sessions
    }

    func build(
        _ request: CmxByteTransportRequest
    ) async throws -> any CmxConnectivitySession {
        _ = request
        let call = calls
        calls += 1
        await withCheckedContinuation { continuation in
            gates[call] = continuation
        }
        return sessions[call]
    }

    func release(call: Int) {
        gates.removeValue(forKey: call)?.resume()
    }

    func callCount() -> Int { calls }
}

private actor TestConnectivitySession: CmxConnectivitySession {
    private let continuityID: UInt64
    private let gatesCloseAttribution: Bool
    private let keepsSelectedPathStreamOpen: Bool
    private let gatesPostCloseCleanup: Bool
    private var closed = false
    private var closes = 0
    private var closeFailure = DiagnosticFailureKind.connectionClosed
    private var closureWaiters: [CheckedContinuation<Void, Never>] = []
    private var closeAttributionWaiter: CheckedContinuation<Void, Never>?
    private var closeAttributionWaiting = false
    private var isClosedGatePending: Bool
    private var isClosedGateWaiting = false
    private var isClosedGateWaiter: CheckedContinuation<Void, Never>?
    private var closeGatePending: Bool
    private var closeGateWaiting = false
    private var closeGateWaiter: CheckedContinuation<Void, Never>?
    private var postCloseCleanupWaiting = false
    private var postCloseCleanupWaiter: CheckedContinuation<Void, Never>?
    private var received: [Data] = []
    private var selectedPath = CmxIrohObservedConnectionPath.direct
    private var selectedPathContinuation:
        AsyncStream<CmxIrohObservedConnectionPath>.Continuation?

    init(
        continuityID: UInt64,
        gatesCloseAttribution: Bool = false,
        keepsSelectedPathStreamOpen: Bool = false,
        gatesFirstIsClosedCheck: Bool = false,
        gatesFirstClose: Bool = false,
        gatesPostCloseCleanup: Bool = false
    ) {
        self.continuityID = continuityID
        self.gatesCloseAttribution = gatesCloseAttribution
        self.keepsSelectedPathStreamOpen = keepsSelectedPathStreamOpen
        self.gatesPostCloseCleanup = gatesPostCloseCleanup
        isClosedGatePending = gatesFirstIsClosedCheck
        closeGatePending = gatesFirstClose
    }

    func receiveControl(maximumByteCount: Int) -> Data? {
        guard maximumByteCount > 0, !received.isEmpty else { return nil }
        return received.removeFirst()
    }

    func sendControl(_ data: Data) {
        received.append(data)
    }

    func openBidirectionalLane(
        _ lane: CmxIrohLane,
        priority: Int32
    ) throws -> CmxIrohBidirectionalStream {
        _ = lane
        _ = priority
        throw TestConnectivitySessionError.unsupported
    }

    func serverEventByteStream() throws -> CmxIndependentEventByteStream {
        throw TestConnectivitySessionError.unsupported
    }

    func waitUntilClosed() async {
        if closed { return }
        await withCheckedContinuation { continuation in
            closureWaiters.append(continuation)
        }
    }

    func closeAttribution() async -> CmxIrohConnectionCloseAttribution {
        if gatesCloseAttribution {
            closeAttributionWaiting = true
            await withCheckedContinuation { continuation in
                closeAttributionWaiter = continuation
            }
            closeAttributionWaiting = false
        }
        return CmxIrohConnectionCloseAttribution(
            initiator: .remote,
            applicationErrorCode: nil,
            failureKind: closeFailure
        )
    }

    func isClosed() async -> Bool {
        if isClosedGatePending {
            isClosedGatePending = false
            isClosedGateWaiting = true
            await withCheckedContinuation { continuation in
                isClosedGateWaiter = continuation
            }
            isClosedGateWaiting = false
        }
        return closed
    }

    func isClosedGateIsWaiting() -> Bool {
        isClosedGateWaiting
    }

    func releaseIsClosedGate() {
        isClosedGateWaiter?.resume()
        isClosedGateWaiter = nil
    }

    func connectionContinuityID() -> UInt64? {
        closed ? nil : continuityID
    }

    func observedSelectedPath() -> CmxIrohObservedConnectionPath {
        closed ? .unavailable : selectedPath
    }

    func observedSelectedPathChanges() -> AsyncStream<CmxIrohObservedConnectionPath> {
        let pair = AsyncStream<CmxIrohObservedConnectionPath>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pair.continuation.yield(closed ? .unavailable : selectedPath)
        guard keepsSelectedPathStreamOpen else {
            pair.continuation.finish()
            return pair.stream
        }
        selectedPathContinuation = pair.continuation
        return pair.stream
    }

    func hasSelectedPathObserver() -> Bool {
        selectedPathContinuation != nil
    }

    func publishSelectedPath(_ path: CmxIrohObservedConnectionPath) {
        selectedPath = path
        selectedPathContinuation?.yield(path)
    }

    func observedPathEvents() -> AsyncStream<CmxIrohConnectionPathEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func close() async {
        if closeGatePending {
            closeGatePending = false
            closeGateWaiting = true
            await withCheckedContinuation { continuation in
                closeGateWaiter = continuation
            }
            closeGateWaiting = false
        }
        closes += 1
        finish(failure: .cancelled)
    }

    func closeGateIsWaiting() -> Bool {
        closeGateWaiting
    }

    func releaseCloseGate() {
        closeGateWaiter?.resume()
        closeGateWaiter = nil
    }

    func waitForPostCloseCleanup() async {
        guard gatesPostCloseCleanup else { return }
        postCloseCleanupWaiting = true
        await withCheckedContinuation { continuation in
            postCloseCleanupWaiter = continuation
        }
        postCloseCleanupWaiting = false
    }

    func postCloseCleanupIsWaiting() -> Bool {
        postCloseCleanupWaiting
    }

    func releasePostCloseCleanup() {
        postCloseCleanupWaiter?.resume()
        postCloseCleanupWaiter = nil
    }

    func finishRemotely(failure: DiagnosticFailureKind) {
        finish(failure: failure)
    }

    func closeCount() -> Int { closes }

    func closeAttributionIsWaiting() -> Bool {
        closeAttributionWaiting
    }

    func releaseCloseAttribution() {
        closeAttributionWaiter?.resume()
        closeAttributionWaiter = nil
    }

    private func finish(failure: DiagnosticFailureKind) {
        guard !closed else { return }
        closed = true
        selectedPath = .unavailable
        selectedPathContinuation?.finish()
        selectedPathContinuation = nil
        closeFailure = failure
        let waiters = closureWaiters
        closureWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private enum TestConnectivitySessionError: Error {
    case unsupported
}
