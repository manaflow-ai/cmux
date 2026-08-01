import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct TransportIncidentPolicyTests {
    private static let second: UInt64 = 1_000_000_000

    private func dialFailed(
        at seconds: UInt64,
        failure: DiagnosticFailureKind = .policyUnavailable,
        transport: DiagnosticTransportKind = .iroh
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: seconds * Self.second,
            a: transport.rawValue,
            b: failure.rawValue,
            c: 1
        )
    }

    private func connected(at seconds: UInt64) -> DiagnosticEvent {
        DiagnosticEvent(code: .transportDialConnected, tNanos: seconds * Self.second, a: 1, c: 1)
    }

    @Test func firstFailureCaptures() {
        var policy = TransportIncidentPolicy()
        let incident = policy.decide(dialFailed(at: 10))
        #expect(incident?.kind == .failure)
        #expect(incident?.severity == .warning)
        #expect(incident?.signature == "transportDialFailed/policyUnavailable/iroh")
        #expect(incident?.coalescedCount == 1)
        #expect(incident?.consecutiveFailures == 1)
    }

    @Test func repeatWithinCooldownCoalesces() {
        var policy = TransportIncidentPolicy()
        #expect(policy.decide(dialFailed(at: 10)) != nil)
        #expect(policy.decide(dialFailed(at: 20)) == nil)
        #expect(policy.decide(dialFailed(at: 30)) == nil)
        // Past the 600s cooldown the next occurrence captures, carrying the
        // two coalesced repeats.
        let recapture = policy.decide(dialFailed(at: 700))
        #expect(recapture != nil)
        #expect(recapture?.coalescedCount == 3)
        #expect(recapture?.secondsSinceFirstCoalesced == 680)
    }

    @Test func distinctSignaturesCaptureIndependently() {
        var policy = TransportIncidentPolicy()
        #expect(policy.decide(dialFailed(at: 10, failure: .policyUnavailable)) != nil)
        #expect(policy.decide(dialFailed(at: 11, failure: .identityMismatch)) != nil)
        #expect(policy.decide(dialFailed(at: 12, failure: .policyUnavailable)) == nil)
    }

    @Test func benignFailureKindsAreSuppressed() {
        var policy = TransportIncidentPolicy()
        #expect(policy.decide(dialFailed(at: 10, failure: .cancelled)) == nil)
        #expect(policy.decide(dialFailed(at: 11, failure: .superseded)) == nil)
        #expect(policy.decide(dialFailed(at: 12, failure: .none)) == nil)
    }

    @Test func offlineSuppressedOnlyWhileUnreachable() {
        var policy = TransportIncidentPolicy()
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0))
        #expect(policy.decide(dialFailed(at: 10, failure: .offline)) == nil)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 11 * Self.second, a: 1))
        #expect(policy.decide(dialFailed(at: 12, failure: .offline)) != nil)
    }

    @Test func offlineReportedWhenReachabilityUnknown() {
        var policy = TransportIncidentPolicy()
        #expect(policy.decide(dialFailed(at: 10, failure: .offline)) != nil)
    }

    @Test func idleTimeoutSuppressedInBackground() {
        var policy = TransportIncidentPolicy()
        _ = policy.decide(DiagnosticEvent(
            code: .appLifecycleChanged,
            tNanos: 1,
            a: DiagnosticAppLifecyclePhase.background.rawValue
        ))
        let backgrounded = DiagnosticEvent(
            code: .sessionClosed,
            tNanos: 10 * Self.second,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.transportIdleTimedOut.rawValue
        )
        #expect(policy.decide(backgrounded) == nil)

        _ = policy.decide(DiagnosticEvent(
            code: .appLifecycleChanged,
            tNanos: 11 * Self.second,
            a: DiagnosticAppLifecyclePhase.active.rawValue
        ))
        let foregrounded = DiagnosticEvent(
            code: .sessionClosed,
            tNanos: 12 * Self.second,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.transportIdleTimedOut.rawValue
        )
        #expect(policy.decide(foregrounded) != nil)
    }

    @Test func expectedSessionCloseIsSuppressed() {
        var policy = TransportIncidentPolicy()
        let close = DiagnosticEvent(code: .sessionClosed, tNanos: Self.second, a: 1, c: 3)
        #expect(policy.decide(close) == nil)
    }

    @Test func pairFailWithoutKindStillCaptures() {
        var policy = TransportIncidentPolicy()
        let incident = policy.decide(DiagnosticEvent(code: .pairFail, tNanos: Self.second))
        #expect(incident?.signature == "pairFail")
    }

    @Test func successResetsStreakAndCooldownKeepsCounting() {
        var policy = TransportIncidentPolicy()
        #expect(policy.decide(dialFailed(at: 10))?.consecutiveFailures == 1)
        #expect(policy.decide(dialFailed(at: 20)) == nil)
        _ = policy.decide(connected(at: 30))
        // New failure after a success starts a fresh streak but stays inside
        // the signature cooldown, so it coalesces rather than captures.
        #expect(policy.decide(dialFailed(at: 40)) == nil)
        let recapture = policy.decide(dialFailed(at: 700))
        #expect(recapture?.consecutiveFailures == 2)
        #expect(recapture?.secondsSinceLastSuccess == 670)
    }

    @Test func outageEscalatesAfterThresholdAndDuration() {
        var policy = TransportIncidentPolicy()
        #expect(policy.decide(dialFailed(at: 10))?.kind == .failure)
        #expect(policy.decide(dialFailed(at: 20)) == nil)
        #expect(policy.decide(dialFailed(at: 30)) == nil)
        #expect(policy.decide(dialFailed(at: 40)) == nil)
        // 5th consecutive failure, 60s after the first: outage fires even
        // though the signature is inside its cooldown.
        let outage = policy.decide(dialFailed(at: 70))
        #expect(outage?.kind == .outage)
        #expect(outage?.severity == .error)
        #expect(outage?.signature == "transport-outage")
        #expect(outage?.consecutiveFailures == 5)

        // While the outage is armed-off, further failures stay quiet.
        #expect(policy.decide(dialFailed(at: 80)) == nil)

        // A success re-arms; a new sustained streak fires a new outage.
        _ = policy.decide(connected(at: 100))
        var last: TransportIncidentPolicy.Incident?
        for t in stride(from: UInt64(4000), through: 4080, by: 20) {
            last = policy.decide(dialFailed(at: t)) ?? last
        }
        #expect(last?.kind == .outage)
    }

    @Test func hourlyBudgetDropsAndReports() {
        var policy = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 0,
                hourlyCaptureLimit: 2,
                outageFailureThreshold: 100,
                outageMinimumDuration: 10_000
            )
        )
        #expect(policy.decide(dialFailed(at: 10)) != nil)
        #expect(policy.decide(dialFailed(at: 20)) != nil)
        #expect(policy.decide(dialFailed(at: 30)) == nil)
        #expect(policy.decide(dialFailed(at: 40)) == nil)
        // Window slides: the first two captures age out after an hour, and the
        // next capture reports what the budget dropped.
        let later = policy.decide(dialFailed(at: 10 + 3700))
        #expect(later != nil)
        #expect(later?.droppedByBudget == 2)
    }

    @Test func budgetDropDoesNotStartASignatureCooldown() {
        var policy = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 600,
                hourlyCaptureLimit: 1,
                outageFailureThreshold: 100,
                outageMinimumDuration: 10_000
            )
        )
        // Exhaust the hourly budget with one signature...
        #expect(policy.decide(dialFailed(at: 10)) != nil)
        // ...then a brand-new signature arrives while the budget is empty.
        let unreachable = DiagnosticEvent(
            code: .pairUnreachable,
            tNanos: 20 * Self.second
        )
        #expect(policy.decide(unreachable) == nil)
        // Once the window slides, the never-captured signature must capture
        // immediately: a budget drop is not a capture, so no cooldown applies.
        let afterWindow = DiagnosticEvent(
            code: .pairUnreachable,
            tNanos: (10 + 3700) * Self.second
        )
        let captured = policy.decide(afterWindow)
        #expect(captured != nil)
        #expect(captured?.coalescedCount == 2)
    }

    @Test func environmentRidesOnIncidents() {
        var policy = TransportIncidentPolicy()
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 1))
        _ = policy.decide(DiagnosticEvent(
            code: .appLifecycleChanged,
            tNanos: 2,
            a: DiagnosticAppLifecyclePhase.active.rawValue
        ))
        let incident = policy.decide(dialFailed(at: 10))
        #expect(incident?.reachable == true)
        #expect(incident?.appPhase == .active)
    }
}
