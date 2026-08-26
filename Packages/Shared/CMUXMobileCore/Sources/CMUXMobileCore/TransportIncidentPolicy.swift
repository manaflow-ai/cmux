public import Foundation

/// Pure decision logic that turns the transport diagnostic event stream into a
/// bounded set of reportable incidents.
///
/// Every diagnostic event is cheap to breadcrumb, but capturing a telemetry
/// *event* per failure would let one retry storm (dial failures every few
/// seconds for hours) flood the project. This policy decides, per event, whether
/// the failure deserves a capture now, coalesces repeats behind a per-signature
/// cooldown, enforces a global hourly budget, and escalates sustained
/// no-connectivity windows into a single high-severity outage incident.
///
/// The type is a value: callers thread it through a lock or actor and feed it
/// events in ring order. Time comes from each event's monotonic `tNanos`, so
/// decisions are deterministic and fully unit-testable with synthesized events.
///
/// Suppression rules encode what an operator can already attribute without a
/// report: failures classified ``DiagnosticFailureKind/cancelled`` or
/// ``DiagnosticFailureKind/superseded`` are lifecycle churn;
/// ``DiagnosticFailureKind/offline`` failures and pairing preflight
/// unreachability while the device reports no network path are expected;
/// ``DiagnosticFailureKind/transportIdleTimedOut`` while backgrounded is
/// suspension, not a defect.
public struct TransportIncidentPolicy: Sendable {
    /// Tunable thresholds. Defaults are chosen so one broken user produces a
    /// handful of well-grouped events per hour, not thousands.
    public struct Configuration: Sendable {
        /// Minimum interval between captures of the same signature.
        public var signatureCooldown: TimeInterval
        /// Sliding-window cap on failure captures (outage incidents are exempt
        /// so escalation is never starved by its own precursors).
        public var hourlyCaptureLimit: Int
        /// Consecutive failure candidates (without an intervening success)
        /// required before an outage incident fires.
        public var outageFailureThreshold: Int
        /// Minimum span between the first and latest failure of the streak
        /// before an outage incident fires.
        public var outageMinimumDuration: TimeInterval
        /// After an outage fires, another cannot fire until this much time
        /// passes or a success resets the streak.
        public var outageRearmInterval: TimeInterval

        public init(
            signatureCooldown: TimeInterval = 600,
            hourlyCaptureLimit: Int = 30,
            outageFailureThreshold: Int = 5,
            outageMinimumDuration: TimeInterval = 60,
            outageRearmInterval: TimeInterval = 3600
        ) {
            self.signatureCooldown = signatureCooldown
            self.hourlyCaptureLimit = hourlyCaptureLimit
            self.outageFailureThreshold = outageFailureThreshold
            self.outageMinimumDuration = outageMinimumDuration
            self.outageRearmInterval = outageRearmInterval
        }
    }

    /// A reportable incident distilled from the event stream.
    public struct Incident: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// One failure signature crossed its capture gate.
            case failure
            /// A sustained streak of failures with no success escalated.
            case outage
        }

        public enum Severity: Sendable, Equatable {
            case warning
            case error
        }

        /// Stable grouping fingerprint, e.g.
        /// `transportDialFailed/policyUnavailable/iroh`.
        public let signature: String
        /// Human-readable one-line summary suitable as an event title.
        public let title: String
        public let kind: Kind
        public let severity: Severity
        /// The event that triggered the incident.
        public let event: DiagnosticEvent
        /// The decoded failure kind of the triggering event, when present.
        public let failure: DiagnosticFailureKind?
        /// The decoded transport kind of the triggering event, when present.
        public let transport: DiagnosticTransportKind?
        /// Occurrences of this signature coalesced into this capture (>= 1),
        /// including the triggering one.
        public let coalescedCount: Int
        /// Seconds since the first coalesced occurrence, when repeats were
        /// coalesced.
        public let secondsSinceFirstCoalesced: Double?
        /// Length of the current no-success failure streak, including this
        /// event.
        public let consecutiveFailures: Int
        /// Seconds since the last success-classified event, when one was seen.
        public let secondsSinceLastSuccess: Double?
        /// Captures dropped by the hourly budget since the last allowed one.
        public let droppedByBudget: Int
        /// Last observed device reachability, when known.
        public let reachable: Bool?
        /// Last observed app lifecycle phase, when known.
        public let appPhase: DiagnosticAppLifecyclePhase?
    }

    /// Creates an incident policy with localized titles.
    ///
    /// - Parameters:
    ///   - configuration: Thresholds and budgets used by the policy.
    ///   - locale: Locale used for human-readable incident titles.
    public init(
        configuration: Configuration = Configuration(),
        locale: Locale = .current
    ) {
        self.configuration = configuration
        self.titleFormatter = DiagnosticIncidentTitleFormatter(locale: locale)
    }

    private let configuration: Configuration
    private let titleFormatter: DiagnosticIncidentTitleFormatter

    // MARK: Streak and environment state (event-time domain, nanoseconds).

    private var lastSuccessTNanos: UInt64?
    private var streakCount = 0
    private var streakFirstTNanos: UInt64?
    private var outageFiredTNanos: UInt64?
    private var reachable: Bool?
    private var appPhase: DiagnosticAppLifecyclePhase?

    /// Per-signature capture gate state. `lastCaptureTNanos` is `nil` while the
    /// signature has been seen but never actually captured (for example when
    /// the hourly budget dropped it), so a budget drop never starts a cooldown.
    private struct SignatureState {
        var lastCaptureTNanos: UInt64?
        var pendingCount: Int
        var firstPendingTNanos: UInt64?
    }

    private var signatureStates: [String: SignatureState] = [:]

    /// Capture timestamps inside the sliding hourly budget window.
    private var captureWindow: [UInt64] = []
    private var droppedByBudget = 0

    /// Event codes that mark the transport as healthy and reset the streak.
    public static let successCodes: Set<DiagnosticEventCode> = [
        .pairOk, .transportDialConnected, .hostAuthenticated, .rpcReady,
        .recoverySucceeded, .endpointActive, .relayPolicyRefreshSucceeded,
        .discoverySucceeded, .admissionSucceeded,
    ]

    /// Event codes that are failure candidates (subject to suppression rules).
    public static let failureCodes: Set<DiagnosticEventCode> = [
        .pairFail, .pairUnreachable, .error, .transportDialFailed,
        .transportDialLegFailed,
        .recoveryFailed, .endpointFailed, .relayPolicyRefreshFailed,
        .sessionClosed, .routeUnavailable, .discoveryFailed, .admissionFailed,
        .hostAuthenticationFailed, .rpcFailed,
    ]

    /// Feed one event, in ring order. Returns an incident when the event
    /// crosses a capture gate; `nil` means breadcrumb-only.
    public mutating func decide(_ event: DiagnosticEvent) -> Incident? {
        switch event.code {
        case .reachabilityChanged:
            reachable = event.a.map { $0 == 1 }
            return nil
        case .appLifecycleChanged:
            appPhase = event.a.flatMap(DiagnosticAppLifecyclePhase.init(rawValue:))
            return nil
        default:
            break
        }

        if Self.successCodes.contains(event.code) {
            lastSuccessTNanos = event.tNanos
            streakCount = 0
            streakFirstTNanos = nil
            outageFiredTNanos = nil
            return nil
        }

        guard Self.failureCodes.contains(event.code) else { return nil }

        let failure = failureKind(of: event)
        guard isReportable(event: event, failure: failure) else { return nil }

        let transport = DiagnosticEventPresentation().transportKind(of: event)
        let signature = Self.signature(code: event.code, failure: failure, transport: transport)

        streakCount += 1
        if streakFirstTNanos == nil {
            streakFirstTNanos = event.tNanos
        }

        if let outage = decideOutage(event: event, signature: signature, failure: failure, transport: transport) {
            return outage
        }

        return decideFailureCapture(
            event: event,
            signature: signature,
            failure: failure,
            transport: transport
        )
    }

    /// The stable grouping fingerprint for a failure event.
    static func signature(
        code: DiagnosticEventCode,
        failure: DiagnosticFailureKind?,
        transport: DiagnosticTransportKind?
    ) -> String {
        var parts = [DiagnosticEventPresentation().name(code)]
        if let failure {
            parts.append(DiagnosticEventPresentation().name(failure))
        }
        if let transport {
            parts.append(DiagnosticEventPresentation().name(transport))
        }
        return parts.joined(separator: "/")
    }

    private func failureKind(of event: DiagnosticEvent) -> DiagnosticFailureKind? {
        if let kind = DiagnosticEventPresentation().failureKind(of: event) {
            return kind
        }
        if event.code == .pairUnreachable {
            return .offline
        }
        return nil
    }

    private func isReportable(event: DiagnosticEvent, failure: DiagnosticFailureKind?) -> Bool {
        switch failure {
        case .some(.none), .some(.cancelled), .some(.superseded):
            // Expected lifecycle churn: an intentional close, a dial replaced by
            // a newer attempt, or a cooperative cancellation.
            return false
        case .some(.offline):
            // Offline failures while the device itself reports no network path
            // are environmental, not diagnosable defects. When reachability is
            // unknown or claims a usable path, an offline classification IS
            // interesting (e.g. a stale local socket).
            return reachable != false
        case .some(.transportIdleTimedOut):
            // Idle expiry while backgrounded is scene suspension. In the
            // foreground it is a real defect (sessions dying under the user).
            return appPhase != .background
        case nil:
            // Codes that never carry a failure kind (pairFail, error) stay
            // reportable; sessionClosed without one is documented as expected.
            return event.code != .sessionClosed
        default:
            return true
        }
    }

    private mutating func decideOutage(
        event: DiagnosticEvent,
        signature: String,
        failure: DiagnosticFailureKind?,
        transport: DiagnosticTransportKind?
    ) -> Incident? {
        guard streakCount >= configuration.outageFailureThreshold,
              let firstTNanos = streakFirstTNanos,
              elapsedSeconds(from: firstTNanos, to: event.tNanos) >= configuration.outageMinimumDuration
        else { return nil }
        if let fired = outageFiredTNanos,
           elapsedSeconds(from: fired, to: event.tNanos) < configuration.outageRearmInterval {
            return nil
        }
        outageFiredTNanos = event.tNanos
        let duration = Int(elapsedSeconds(from: firstTNanos, to: event.tNanos).rounded())
        let title = titleFormatter.outageTitle(
            event: event,
            consecutiveFailures: streakCount,
            durationSeconds: duration
        )
        return Incident(
            signature: "transport-outage",
            title: title,
            kind: .outage,
            severity: .error,
            event: event,
            failure: failure,
            transport: transport,
            coalescedCount: streakCount,
            secondsSinceFirstCoalesced: elapsedSeconds(from: firstTNanos, to: event.tNanos),
            consecutiveFailures: streakCount,
            secondsSinceLastSuccess: lastSuccessTNanos.map { elapsedSeconds(from: $0, to: event.tNanos) },
            droppedByBudget: 0,
            reachable: reachable,
            appPhase: appPhase
        )
    }

    private mutating func decideFailureCapture(
        event: DiagnosticEvent,
        signature: String,
        failure: DiagnosticFailureKind?,
        transport: DiagnosticTransportKind?
    ) -> Incident? {
        if var state = signatureStates[signature], let lastCapture = state.lastCaptureTNanos {
            let sinceCapture = elapsedSeconds(from: lastCapture, to: event.tNanos)
            if sinceCapture < configuration.signatureCooldown {
                state.pendingCount += 1
                if state.firstPendingTNanos == nil {
                    state.firstPendingTNanos = event.tNanos
                }
                signatureStates[signature] = state
                return nil
            }
        }

        guard admitCaptureWithinBudget(at: event.tNanos) else {
            var state = signatureStates[signature]
                ?? SignatureState(lastCaptureTNanos: nil, pendingCount: 0, firstPendingTNanos: nil)
            state.pendingCount += 1
            if state.firstPendingTNanos == nil {
                state.firstPendingTNanos = event.tNanos
            }
            signatureStates[signature] = state
            droppedByBudget += 1
            return nil
        }

        let previous = signatureStates[signature]
        let coalescedCount = (previous?.pendingCount ?? 0) + 1
        let firstCoalescedTNanos = previous?.firstPendingTNanos
        signatureStates[signature] = SignatureState(
            lastCaptureTNanos: event.tNanos,
            pendingCount: 0,
            firstPendingTNanos: nil
        )
        let dropped = droppedByBudget
        droppedByBudget = 0

        let title = titleFormatter.failureTitle(
            event: event,
            occurrenceCount: coalescedCount
        )
        return Incident(
            signature: signature,
            title: title,
            kind: .failure,
            severity: .warning,
            event: event,
            failure: failure,
            transport: transport,
            coalescedCount: coalescedCount,
            secondsSinceFirstCoalesced: firstCoalescedTNanos.map {
                elapsedSeconds(from: $0, to: event.tNanos)
            },
            consecutiveFailures: streakCount,
            secondsSinceLastSuccess: lastSuccessTNanos.map { elapsedSeconds(from: $0, to: event.tNanos) },
            droppedByBudget: dropped,
            reachable: reachable,
            appPhase: appPhase
        )
    }

    /// Sliding-window budget admission for failure captures.
    private mutating func admitCaptureWithinBudget(at tNanos: UInt64) -> Bool {
        let windowNanos: UInt64 = 3_600_000_000_000
        captureWindow.removeAll { tNanos >= $0 && tNanos - $0 > windowNanos }
        guard captureWindow.count < configuration.hourlyCaptureLimit else { return false }
        captureWindow.append(tNanos)
        return true
    }

    private func elapsedSeconds(from: UInt64, to: UInt64) -> Double {
        guard to > from else { return 0 }
        return Double(to - from) / 1_000_000_000
    }
}
