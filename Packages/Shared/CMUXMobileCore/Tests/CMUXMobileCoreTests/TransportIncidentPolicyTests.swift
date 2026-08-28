import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct TransportIncidentPolicyTests {
    private static let second: UInt64 = 1_000_000_000
    private var englishLocale: Locale { Locale(identifier: "en") }

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
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let incident = policy.decide(dialFailed(at: 10))
        #expect(incident?.kind == .failure)
        #expect(incident?.severity == .warning)
        #expect(incident?.signature == "transportDialFailed/policyUnavailable/iroh")
        #expect(
            incident?.title
                == "Transport dial failed (Transport: Iroh, Failure: Relay policy unavailable, Attempt: 1)"
        )
        #expect(incident?.coalescedCount == 1)
        #expect(incident?.consecutiveFailures == 1)
    }

    @Test func repeatWithinCooldownCoalesces() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10)) != nil)
        #expect(policy.decide(dialFailed(at: 20)) == nil)
        #expect(policy.decide(dialFailed(at: 30)) == nil)
        // Past the 600s cooldown the next occurrence captures, carrying the
        // two coalesced repeats.
        let recapture = policy.decide(dialFailed(at: 700))
        #expect(recapture != nil)
        #expect(recapture?.coalescedCount == 3)
        #expect(recapture?.secondsSinceFirstCoalesced == 680)
        let expectedTitle = "Transport dial failed "
            + "(Transport: Iroh, Failure: Relay policy unavailable, Attempt: 1) "
            + "(3 occurrences)"
        #expect(
            recapture?.title == expectedTitle
        )
    }

    @Test func distinctSignaturesCaptureIndependently() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10, failure: .policyUnavailable)) != nil)
        #expect(policy.decide(dialFailed(at: 11, failure: .identityMismatch)) != nil)
        #expect(policy.decide(dialFailed(at: 12, failure: .policyUnavailable)) == nil)
    }

    @Test func benignFailureKindsAreSuppressed() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10, failure: .cancelled)) == nil)
        #expect(policy.decide(dialFailed(at: 11, failure: .superseded)) == nil)
        #expect(policy.decide(dialFailed(at: 12, failure: .none)) == nil)
    }

    @Test func offlineSuppressedOnlyWhileUnreachable() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0))
        #expect(policy.decide(dialFailed(at: 10, failure: .offline)) == nil)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 11 * Self.second, a: 1))
        #expect(policy.decide(dialFailed(at: 12, failure: .offline)) != nil)
    }

    @Test func offlineReportedWhenReachabilityUnknown() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10, failure: .offline)) != nil)
    }

    @Test func idleTimeoutSuppressedInBackground() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
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
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let close = DiagnosticEvent(code: .sessionClosed, tNanos: Self.second, a: 1, c: 3)
        #expect(policy.decide(close) == nil)
    }

    @Test func pairFailWithoutKindStillCaptures() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let incident = policy.decide(DiagnosticEvent(code: .pairFail, tNanos: Self.second))
        #expect(incident?.signature == "pairFail")
    }

    @Test func successResetsStreakAndCooldownKeepsCounting() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
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
        var policy = TransportIncidentPolicy(locale: englishLocale)
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
        let expectedTitle = "Transport outage: 5 consecutive failures over 60 seconds. "
            + "Latest: Transport dial failed "
            + "(Transport: Iroh, Failure: Relay policy unavailable, Attempt: 1)"
        #expect(
            outage?.title == expectedTitle
        )

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

    @Test func outageTitlePluralizesFailureAndDurationCounts() {
        var oneFailure = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 0,
                hourlyCaptureLimit: 30,
                outageFailureThreshold: 1,
                outageMinimumDuration: 0
            ),
            locale: englishLocale
        )
        let first = oneFailure.decide(dialFailed(at: 10))
        #expect(first?.title.contains("1 consecutive failure over 0 seconds") == true)

        var oneSecond = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 0,
                hourlyCaptureLimit: 30,
                outageFailureThreshold: 2,
                outageMinimumDuration: 1
            ),
            locale: englishLocale
        )
        _ = oneSecond.decide(dialFailed(at: 10))
        let second = oneSecond.decide(dialFailed(at: 11))
        #expect(second?.title.contains("2 consecutive failures over 1 second") == true)
    }

    @Test func hourlyBudgetDropsAndReports() {
        var policy = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 0,
                hourlyCaptureLimit: 2,
                outageFailureThreshold: 100,
                outageMinimumDuration: 10_000
            ),
            locale: englishLocale
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
            ),
            locale: englishLocale
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
        var policy = TransportIncidentPolicy(locale: englishLocale)
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

    // MARK: Peer-unreachable demotion

    @Test func peerUnreachableFailuresAreBreadcrumbOnly() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 1))
        #expect(policy.decide(dialFailed(at: 10, failure: .timedOut)) == nil)
        #expect(policy.decide(dialFailed(at: 20, failure: .noRoute)) == nil)
        #expect(policy.decide(dialFailed(at: 30, failure: .hostUnreachable)) == nil)
        #expect(policy.decide(dialFailed(at: 40, failure: .connectionRefused)) == nil)
    }

    @Test func peerUnreachableDemotedAtUnknownReachability() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10, failure: .timedOut)) == nil)
        #expect(policy.decide(dialFailed(at: 20, failure: .noRoute)) == nil)
    }

    @Test func peerUnreachableStillCapturesWhileDeviceOffline() {
        // While the device itself reports no network path the pre-demotion
        // capture behavior is preserved: offline-state suppression has its
        // own owner (the offline relay/transport quieting work).
        var policy = TransportIncidentPolicy(locale: englishLocale)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0))
        #expect(policy.decide(dialFailed(at: 10, failure: .timedOut)) != nil)
    }

    @Test func demotedPeerUnreachableStreakStillEscalatesToOutage() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10, failure: .noRoute)) == nil)
        #expect(policy.decide(dialFailed(at: 20, failure: .noRoute)) == nil)
        #expect(policy.decide(dialFailed(at: 30, failure: .timedOut)) == nil)
        #expect(policy.decide(dialFailed(at: 40, failure: .noRoute)) == nil)
        // 5th consecutive demoted failure, 60s after the first: the outage
        // escalator still fires even though every precursor was
        // breadcrumb-only.
        let outage = policy.decide(dialFailed(at: 70, failure: .noRoute))
        #expect(outage?.kind == .outage)
        #expect(outage?.severity == .error)
        #expect(outage?.consecutiveFailures == 5)
    }

    @Test func successResetsDemotedStreak() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        for t in [10, 20, 30, 40] as [UInt64] {
            #expect(policy.decide(dialFailed(at: t, failure: .noRoute)) == nil)
        }
        _ = policy.decide(connected(at: 50))
        // The success reset the streak: the next demoted failures need a
        // fresh threshold and 60s window before an outage can fire.
        for t in [60, 70, 80, 90, 100] as [UInt64] {
            #expect(policy.decide(dialFailed(at: t, failure: .noRoute)) == nil)
        }
        let outage = policy.decide(dialFailed(at: 120, failure: .noRoute))
        #expect(outage?.kind == .outage)
    }

    @Test func demotedFailuresDoNotConsumeCaptureBudget() {
        var policy = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 0,
                hourlyCaptureLimit: 1,
                outageFailureThreshold: 100,
                outageMinimumDuration: 10_000
            ),
            locale: englishLocale
        )
        #expect(policy.decide(dialFailed(at: 10, failure: .timedOut)) == nil)
        #expect(policy.decide(dialFailed(at: 20, failure: .noRoute)) == nil)
        // The whole budget is still available for the first diagnosable defect.
        #expect(policy.decide(dialFailed(at: 30, failure: .policyUnavailable)) != nil)
    }

    // MARK: Route-gated suppression

    @Test func routeGatedIsFullySuppressed() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10, failure: .routeGated)) == nil)
    }

    @Test func routeGatedDoesNotFeedTheOutageStreak() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        for t in [10, 20, 30, 40] as [UInt64] {
            #expect(policy.decide(dialFailed(at: t, failure: .routeGated)) == nil)
        }
        // A gated dial never reached the network: after four of them this
        // demoted failure is a streak of one, so no outage fires.
        #expect(policy.decide(dialFailed(at: 70, failure: .noRoute)) == nil)
        let capture = policy.decide(dialFailed(at: 80, failure: .policyUnavailable))
        #expect(capture?.kind == .failure)
        #expect(capture?.consecutiveFailures == 2)
    }

    // MARK: Connect-phase connection closes

    @Test func connectionClosedDuringConnectIsBreadcrumbOnly() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let pairClose = DiagnosticEvent(
            code: .pairFail,
            tNanos: 10 * Self.second,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.connectionClosed.rawValue
        )
        #expect(policy.decide(pairClose) == nil)
        let legClose = DiagnosticEvent(
            code: .transportDialLegFailed,
            tNanos: 20 * Self.second,
            a: DiagnosticDirectDialLeg.publicPaths.rawValue,
            b: DiagnosticFailureKind.connectionClosed.rawValue
        )
        #expect(policy.decide(legClose) == nil)
        #expect(policy.decide(dialFailed(at: 30, failure: .connectionClosed)) == nil)
    }

    @Test func connectionClosedOnEstablishedSessionStillCaptures() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let rpcClose = DiagnosticEvent(
            code: .rpcFailed,
            tNanos: 10 * Self.second,
            a: DiagnosticTransportKind.iroh.rawValue,
            b: DiagnosticFailureKind.connectionClosed.rawValue
        )
        let incident = policy.decide(rpcClose)
        #expect(incident?.kind == .failure)
        #expect(incident?.signature == "rpcFailed/connectionClosed/iroh")
    }

    // MARK: Coded generic errors

    @Test func codedSubscriptionStreamCloseIsBreadcrumbOnly() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let streamEndedBeforeAck = DiagnosticEvent(
            code: .error,
            tNanos: 10 * Self.second,
            b: DiagnosticFailureKind.connectionClosed.rawValue
        )
        #expect(policy.decide(streamEndedBeforeAck) == nil)
    }

    @Test func codedSubscriptionNackCapturesWithItsKind() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let nack = DiagnosticEvent(
            code: .error,
            tNanos: 10 * Self.second,
            b: DiagnosticFailureKind.protocolViolation.rawValue
        )
        let incident = policy.decide(nack)
        #expect(incident?.kind == .failure)
        #expect(incident?.failure == .protocolViolation)
        #expect(incident?.signature == "error/protocolViolation")
    }

    @Test func bareErrorRemainsCapturable() {
        // Writers from older builds still record `.error` with no kind; those
        // must stay visible rather than silently vanishing.
        var policy = TransportIncidentPolicy(locale: englishLocale)
        let incident = policy.decide(DiagnosticEvent(code: .error, tNanos: Self.second))
        #expect(incident?.signature == "error")
    }
}
