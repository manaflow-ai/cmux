import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct TransportIncidentPolicyTests {
    private static let second: UInt64 = 1_000_000_000
    private var englishLocale: Locale { Locale(identifier: "en") }

    private func dialFailed(
        at seconds: UInt64,
        failure: DiagnosticFailureKind = .policyUnavailable,
        transport: DiagnosticTransportKind = .iroh,
        attempt: Int = 1
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            code: .transportDialFailed,
            tNanos: seconds * Self.second,
            a: transport.rawValue,
            b: failure.rawValue,
            c: attempt
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

    @Test func explicitOfflineClassificationIsAlwaysSuppressed() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0))
        #expect(policy.decide(dialFailed(at: 10, failure: .offline)) == nil)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 11 * Self.second, a: 1))
        #expect(policy.decide(dialFailed(at: 12, failure: .offline)) == nil)
    }

    @Test func offlineSuppressedWhenReachabilityUnknown() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        #expect(policy.decide(dialFailed(at: 10, failure: .offline)) == nil)
    }

    @Test func offlinePathSuppressesTransientPolicyAndEndpointFailures() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0))

        #expect(policy.decide(dialFailed(at: 10, failure: .policyUnavailable)) == nil)
        #expect(policy.decide(dialFailed(at: 11, failure: .endpointUnavailable)) == nil)
        #expect(policy.decide(dialFailed(at: 12, failure: .authorizationFailed)) == nil)
        #expect(policy.decide(dialFailed(at: 13, failure: .unknown)) == nil)
    }

    @Test func offlineFailuresDoNotEscalateAnOutage() {
        var policy = TransportIncidentPolicy(locale: englishLocale)
        _ = policy.decide(DiagnosticEvent(code: .reachabilityChanged, tNanos: 1, a: 0))

        for second in stride(from: UInt64(10), through: 200, by: 30) {
            #expect(policy.decide(dialFailed(at: second, failure: .policyUnavailable)) == nil)
        }
    }

    @Test func macHostConfigurationUsesSamplingAndLongerGates() {
        let configuration = TransportIncidentPolicy.Configuration.macHost
        #expect(configuration.signatureCooldown >= 3_600)
        #expect(configuration.hourlyCaptureLimit <= 10)
        #expect(configuration.failureSampleRate == 0.05)
        #expect(configuration.outageSampleRate == 0.25)
        #expect(configuration.suppressOfflineFailures)
    }

    @Test func zeroFailureSampleRateKeepsBreadcrumbOnlySemantics() {
        var policy = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 0,
                hourlyCaptureLimit: 30,
                outageFailureThreshold: 100,
                outageMinimumDuration: 10_000,
                outageRearmInterval: 3_600,
                failureSampleRate: 0,
                outageSampleRate: 0
            ),
            locale: englishLocale
        )

        #expect(policy.decide(dialFailed(at: 10)) == nil)
        #expect(policy.decide(dialFailed(at: 20)) == nil)
    }

    @Test func fractionalFailureSamplingIsDeterministicAndBounded() {
        var policy = TransportIncidentPolicy(
            configuration: .init(
                signatureCooldown: 0,
                hourlyCaptureLimit: 2_000,
                outageFailureThreshold: 10_000,
                outageMinimumDuration: 10_000,
                outageRearmInterval: 3_600,
                failureSampleRate: 0.05,
                outageSampleRate: 0.25
            ),
            locale: englishLocale
        )
        var captures = 0
        for index in 0 ..< 1_000 {
            if policy.decide(dialFailed(
                at: UInt64(index + 1),
                attempt: index
            )) != nil {
                captures += 1
            }
        }

        // The deterministic hash should retain roughly 5% of ordinary
        // failures; keep the assertion broad enough to be stable across
        // compiler/platform implementations while still catching a disabled
        // or unbounded sampler.
        #expect(captures > 10)
        #expect(captures < 120)
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
        let identityMismatch = dialFailed(at: 20, failure: .identityMismatch)
        #expect(policy.decide(identityMismatch) == nil)
        // Once the window slides, the never-captured signature must capture
        // immediately: a budget drop is not a capture, so no cooldown applies.
        let afterWindow = dialFailed(
            at: 10 + 3700,
            failure: .identityMismatch
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
}
