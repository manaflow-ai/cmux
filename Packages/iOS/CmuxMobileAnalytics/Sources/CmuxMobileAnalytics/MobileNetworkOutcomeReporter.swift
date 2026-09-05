public import CMUXMobileCore
internal import Foundation
internal import os

/// Emits one bounded latency observation when a connectivity phase completes.
///
/// Starts stay local. Only terminal outcomes reach Axiom, which keeps the
/// operational stream useful for latency histograms without turning every
/// retry or state transition into an event. The diagnostic ring remains the
/// source for Sentry's incident policy and the on-device logs.
public final class MobileNetworkOutcomeReporter: Sendable {
    public static let eventName = "ios_connectivity_latency"

    private enum Phase: String, Hashable, Sendable {
        case endpointStart = "endpoint_start"
        case pairing
        case transportDial = "transport_dial"
        case hostAuth = "host_auth"
        case rpcReady = "rpc_ready"
        case recovery
        case relayPolicy = "relay_policy"
        case discovery
    }

    private struct Key: Hashable, Sendable {
        let phase: Phase
        let correlation: UInt32?
    }

    private struct Start: Sendable {
        let tNanos: UInt64
        let transport: DiagnosticTransportKind?
    }

    private struct State: Sendable {
        var starts: [Key: Start] = [:]
        var connectStarts: [Start] = []
        var hostAuthStarts: [UInt32?: Start] = [:]
    }

    private static let pendingStartLifetimeNanos: UInt64 = 5 * 60 * 1_000_000_000
    private static let maxPendingStarts = 32

    private struct Observation: Sendable {
        let phase: Phase
        let outcome: String
        let durationMs: UInt32
        let transport: DiagnosticTransportKind?
        let failure: DiagnosticFailureKind?
        let userUsable: Bool
    }

    private let emitter: any AnalyticsEmitting
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(emitter: any AnalyticsEmitting) {
        self.emitter = emitter
    }

    /// Considers one diagnostic event without doing I/O or spawning a task.
    public func ingest(_ event: DiagnosticEvent) {
        guard let observation = state.withLock({ state in
            Self.observe(event, state: &state)
        }) else { return }
        emitter.capture(Self.eventName, Self.properties(for: observation))
    }

    public func flush() async {
        await emitter.flush()
    }

    /// Builds a terminal latency payload for an event that already carries a
    /// measured duration. This keeps direct event-level tests simple.
    static func properties(for event: DiagnosticEvent) -> [String: AnalyticsValue]? {
        guard let phase = Self.phase(for: event.code),
              let duration = event.ms,
              let observation = Self.observation(
                  phase: phase,
                  event: event,
                  durationMs: duration,
                  transport: Self.transport(for: event),
                  userUsable: event.code == .rpcReady
                      || event.code == .recoverySucceeded
              )
        else { return nil }
        return Self.properties(for: observation)
    }

    private static func observe(
        _ event: DiagnosticEvent,
        state: inout State
    ) -> Observation? {
        state.starts = state.starts.filter { entry in
            let start = entry.value
            return event.tNanos >= start.tNanos
                && event.tNanos - start.tNanos <= Self.pendingStartLifetimeNanos
        }
        state.connectStarts.removeAll { start in
            event.tNanos < start.tNanos
                || event.tNanos - start.tNanos > Self.pendingStartLifetimeNanos
        }
        state.hostAuthStarts = state.hostAuthStarts.filter { _, start in
            event.tNanos >= start.tNanos
                && event.tNanos - start.tNanos <= Self.pendingStartLifetimeNanos
        }
        let transport = Self.transport(for: event)
        switch event.code {
        case .connect:
            Self.appendBounded(Start(tNanos: event.tNanos, transport: transport), to: &state.connectStarts)
            return nil

        case .pairOk, .pairFail, .pairUnreachable:
            let start = state.connectStarts.isEmpty ? nil : state.connectStarts.removeFirst()
            return Self.terminal(
                phase: .pairing,
                event: event,
                start: start,
                transport: transport,
                userUsable: event.code == .pairOk
            )

        case .transportDialStarted:
            Self.storeStart(Start(
                tNanos: event.tNanos,
                transport: transport
            ), for: Key(
                phase: .transportDial,
                correlation: Self.correlation(event.c)
            ), state: &state)
            return nil

        case .transportDialConnected, .transportDialFailed, .transportDialCancelled:
            let key = Key(
                phase: .transportDial,
                correlation: Self.correlation(event.c)
            )
            let start = state.starts.removeValue(forKey: key)
            if event.code == .transportDialConnected {
                Self.storeHostAuthStart(Start(
                    tNanos: event.tNanos,
                    transport: transport ?? start?.transport
                ), surface: event.surface, state: &state)
            }
            return Self.terminal(
                phase: .transportDial,
                event: event,
                start: start,
                transport: transport ?? start?.transport,
                userUsable: false
            )

        case .hostAuthenticated, .hostAuthenticationFailed:
            let start = state.hostAuthStarts.removeValue(forKey: event.surface)
            return Self.terminal(
                phase: .hostAuth,
                event: event,
                start: start,
                transport: transport ?? start?.transport,
                userUsable: false
            )

        case .rpcReady:
            let start = state.connectStarts.isEmpty ? nil : state.connectStarts.removeFirst()
            return Self.terminal(
                phase: .rpcReady,
                event: event,
                start: start,
                transport: transport ?? start?.transport,
                userUsable: true
            )

        case .recoveryStarted:
            Self.storeStart(Start(
                tNanos: event.tNanos,
                transport: transport
            ), for: Key(
                phase: .recovery,
                correlation: Self.correlation(event.surface)
            ), state: &state)
            return nil

        case .recoverySucceeded, .recoveryFailed:
            let key = Key(
                phase: .recovery,
                correlation: Self.correlation(event.surface)
            )
            let start = state.starts.removeValue(forKey: key)
            return Self.terminal(
                phase: .recovery,
                event: event,
                start: start,
                transport: transport ?? start?.transport,
                userUsable: event.code == .recoverySucceeded
            )

        case .endpointStarting:
            Self.storeStart(Start(
                tNanos: event.tNanos,
                transport: transport
            ), for: Key(phase: .endpointStart, correlation: nil), state: &state)
            return nil

        case .endpointActive, .endpointFailed:
            let start = state.starts.removeValue(
                forKey: Key(phase: .endpointStart, correlation: nil)
            )
            return Self.terminal(
                phase: .endpointStart,
                event: event,
                start: start,
                transport: transport ?? start?.transport,
                userUsable: false
            )

        case .relayPolicyRefreshStarted:
            Self.storeStart(Start(
                tNanos: event.tNanos,
                transport: transport
            ), for: Key(phase: .relayPolicy, correlation: nil), state: &state)
            return nil

        case .relayPolicyRefreshSucceeded, .relayPolicyRefreshFailed:
            let start = state.starts.removeValue(
                forKey: Key(phase: .relayPolicy, correlation: nil)
            )
            return Self.terminal(
                phase: .relayPolicy,
                event: event,
                start: start,
                transport: transport ?? start?.transport,
                userUsable: false
            )

        case .discoverySucceeded, .discoveryFailed:
            guard let duration = event.ms else { return nil }
            return Self.terminal(
                phase: .discovery,
                event: event,
                start: nil,
                durationMs: duration,
                transport: transport,
                userUsable: false
            )

        default:
            return nil
        }
    }

    private static func terminal(
        phase: Phase,
        event: DiagnosticEvent,
        start: Start?,
        durationMs: UInt32? = nil,
        transport: DiagnosticTransportKind?,
        userUsable: Bool
    ) -> Observation? {
        let duration = durationMs ?? event.ms ?? start.flatMap {
            elapsedMilliseconds(from: $0.tNanos, to: event.tNanos)
        }
        guard let duration else { return nil }
        return observation(
            phase: phase,
            event: event,
            durationMs: duration,
            transport: transport,
            userUsable: userUsable
        )
    }

    private static func storeStart(_ start: Start, for key: Key, state: inout State) {
        if state.starts[key] == nil, state.starts.count >= Self.maxPendingStarts,
           let oldest = state.starts.min(by: { $0.value.tNanos < $1.value.tNanos })?.key {
            state.starts.removeValue(forKey: oldest)
        }
        state.starts[key] = start
    }

    private static func appendBounded(_ start: Start, to starts: inout [Start]) {
        if starts.count >= Self.maxPendingStarts {
            starts.removeFirst()
        }
        starts.append(start)
    }

    private static func storeHostAuthStart(
        _ start: Start,
        surface: UInt32?,
        state: inout State
    ) {
        if state.hostAuthStarts[surface] == nil,
           state.hostAuthStarts.count >= Self.maxPendingStarts,
           let oldest = state.hostAuthStarts.min(by: { $0.value.tNanos < $1.value.tNanos })?.key {
            state.hostAuthStarts.removeValue(forKey: oldest)
        }
        state.hostAuthStarts[surface] = start
    }

    private static func observation(
        phase: Phase,
        event: DiagnosticEvent,
        durationMs: UInt32,
        transport: DiagnosticTransportKind?,
        userUsable: Bool
    ) -> Observation? {
        let failure = DiagnosticEventPresentation().failureKind(of: event)
        let failureKind = failure == DiagnosticFailureKind.none ? nil : failure
        let outcome: String
        if event.code == .transportDialCancelled
            || failureKind == .cancelled
            || failureKind == .superseded {
            outcome = "cancelled"
        } else if failureKind == .timedOut || failureKind == .transportIdleTimedOut {
            outcome = "timeout"
        } else if failureKind != nil || Self.isFailureCode(event.code) {
            outcome = "failure"
        } else {
            outcome = "success"
        }
        return Observation(
            phase: phase,
            outcome: outcome,
            durationMs: durationMs,
            transport: transport,
            failure: failureKind,
            userUsable: userUsable
        )
    }

    private static func isFailureCode(_ code: DiagnosticEventCode) -> Bool {
        switch code {
        case .pairFail, .pairUnreachable, .error, .transportDialFailed,
             .transportDialLegFailed, .recoveryFailed, .endpointFailed,
             .relayPolicyRefreshFailed, .sessionClosed, .routeUnavailable,
             .discoveryFailed, .admissionFailed, .hostAuthenticationFailed,
             .rpcFailed:
            true
        default:
            false
        }
    }

    private static func properties(for observation: Observation) -> [String: AnalyticsValue] {
        var properties: [String: AnalyticsValue] = [
            "phase": .string(observation.phase.rawValue),
            "outcome": .string(observation.outcome),
            "duration_ms": .int(Int(observation.durationMs)),
            "user_usable": .bool(observation.userUsable),
        ]
        let presentation = DiagnosticEventPresentation(locale: Locale(identifier: "en_US_POSIX"))
        if let transport = observation.transport {
            properties["transport"] = .string(presentation.name(transport))
        }
        if let failure = observation.failure {
            properties["failure"] = .string(presentation.name(failure))
        }
        return properties
    }

    private static func phase(for code: DiagnosticEventCode) -> Phase? {
        switch code {
        case .transportDialConnected, .transportDialFailed, .transportDialCancelled:
            .transportDial
        case .hostAuthenticated, .hostAuthenticationFailed:
            .hostAuth
        case .rpcReady:
            .rpcReady
        case .recoverySucceeded, .recoveryFailed:
            .recovery
        case .endpointActive, .endpointFailed:
            .endpointStart
        case .relayPolicyRefreshSucceeded, .relayPolicyRefreshFailed:
            .relayPolicy
        case .discoverySucceeded, .discoveryFailed:
            .discovery
        default:
            nil
        }
    }

    private static func transport(for event: DiagnosticEvent) -> DiagnosticTransportKind? {
        DiagnosticEventPresentation().transportKind(of: event)
    }

    private static func correlation(_ raw: Int?) -> UInt32? {
        guard let raw, raw > 0 else { return nil }
        return UInt32(clamping: raw)
    }

    private static func correlation(_ raw: UInt32?) -> UInt32? {
        raw
    }

    private static func elapsedMilliseconds(from start: UInt64, to end: UInt64) -> UInt32? {
        guard end >= start else { return nil }
        return UInt32(clamping: Int((end - start) / 1_000_000))
    }
}
