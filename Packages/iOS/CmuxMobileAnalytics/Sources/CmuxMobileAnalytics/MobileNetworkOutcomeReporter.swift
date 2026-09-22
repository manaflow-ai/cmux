public import CMUXMobileCore
internal import Foundation

/// Emits one bounded latency observation when a connectivity phase completes.
///
/// Starts stay local. Only terminal outcomes reach Axiom, which keeps the
/// operational stream useful for latency histograms without turning every
/// retry or state transition into an event. The diagnostic ring remains the
/// source for Sentry's incident policy and the on-device logs.
private func taskModelProperties(
    for kind: DiagnosticAppEventKind,
    event: DiagnosticEvent
) -> [String: AnalyticsValue]? {
    let outcome: String
    let phase: String?
    switch kind {
    case .taskModelListLoadSucceeded:
        outcome = "success"
        phase = nil
    case .taskModelListLoadFailed:
        outcome = "failure"
        phase = nil
    case .taskModelListRetryScheduled:
        outcome = "failure"
        phase = "retry_scheduled"
    case .taskModelListRetryStopped:
        outcome = "failure"
        phase = "retry_stopped"
    default:
        return nil
    }
    let modelCount: Int
    switch kind {
    case .taskModelListRetryScheduled, .taskModelListRetryStopped:
        modelCount = 0
    default:
        modelCount = event.c ?? 0
    }
    let requestDurationMilliseconds: Int
    switch kind {
    case .taskModelListRetryScheduled:
        // The event's duration slot carries the backoff for this phase. The
        // request duration is unavailable here, so keep latency histograms
        // honest instead of treating the sleep as network work.
        requestDurationMilliseconds = 0
    default:
        requestDurationMilliseconds = Int(event.ms ?? 0)
    }
    var properties: [String: AnalyticsValue] = [
        "operation": .string("model_list"),
        "outcome": .string(outcome),
        // Transport failures can precede a catalog result. The ingress
        // requires this field even when discovery produced no models.
        "model_count": .int(modelCount),
        "duration_ms": .int(requestDurationMilliseconds),
    ]
    if let surface = event.surface {
        // This is the existing process-local correlation handle. It lets
        // Axiom join one refresh's retries without exporting the Mac ID.
        properties["correlation_id"] = .int(Int(surface))
    }
    if let phase {
        properties["phase"] = .string(phase)
    }
    let failure = DiagnosticEventPresentation().failureKind(of: event)
    if let failure, failure != .none {
        properties["failure"] = .string(DiagnosticEventPresentation().name(failure))
    }
    switch kind {
    case .taskModelListRetryScheduled:
        properties["attempt"] = .int(event.c ?? 0)
        properties["retry_delay_ms"] = .int(Int(event.ms ?? 0))
    case .taskModelListRetryStopped:
        if let reason = event.c.flatMap(DiagnosticTaskModelRetryStopReason.init(rawValue:)) {
            properties["stop_reason"] = .string(DiagnosticEventPresentation().name(reason))
        }
    default:
        break
    }
    return properties
}

/// Reports bounded connectivity and task model discovery outcomes.
public final class MobileNetworkOutcomeReporter: Sendable {
    /// The Axiom event name for connectivity latency diagnostics.
    public static let eventName = "ios_connectivity_latency"
    /// The Axiom event name for task model discovery diagnostics.
    public static let taskModelEventName = "ios_task_model_discovery"

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
        var connectStarts: [UInt32?: [Start]] = [:]
        var readinessStarts: [UInt32?: Start] = [:]
        var hostAuthStarts: [UInt32?: Start] = [:]
    }

    private final class StateStore: @unchecked Sendable {
        // Carve-out: ordered diagnostic callback delivery; the producer cannot suspend.
        private let queue = DispatchQueue(label: "com.cmux.mobile-network-outcomes")
        // Carve-out: nonblocking admission bounds synchronous event-tap work before it is queued.
        private let permits = DispatchSemaphore(value: 128)
        private var state = State()

        func enqueue(
            _ event: DiagnosticEvent,
            emit: @escaping @Sendable (Observation) -> Void
        ) {
            guard permits.wait(timeout: .now()) == .success else { return }
            queue.async { [self] in
                defer { permits.signal() }
                guard let observation = MobileNetworkOutcomeReporter.observe(event, state: &state) else {
                    return
                }
                emit(observation)
            }
        }

        func drain() async {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume()
                }
            }
        }
    }

    private static let pendingStartLifetimeNanos: UInt64 = 5 * 60 * 1_000_000_000
    private static let maxPendingStarts = 32
    private static let maxPendingCorrelationKeys = 32

    private struct Observation: Sendable {
        let phase: Phase
        let outcome: String
        let durationMs: UInt32
        let transport: DiagnosticTransportKind?
        let failure: DiagnosticFailureKind?
        let userUsable: Bool
        /// The originating diagnostic event is retained as fixed vocabulary
        /// plus its bounded integer slots. This lets Axiom reconstruct the
        /// exact transport lifecycle edge without exporting error text,
        /// addresses, peer IDs, or terminal content.
        let event: DiagnosticEvent
    }

    private let emitter: any AnalyticsEmitting
    private let state = StateStore()

    public init(emitter: any AnalyticsEmitting) {
        self.emitter = emitter
    }

    /// Queues one diagnostic event without blocking the diagnostic event tap.
    public func ingest(_ event: DiagnosticEvent) {
        if event.code == .appFeatureAction,
           let kind = event.a.flatMap(DiagnosticAppEventKind.init(rawValue:)),
           let properties = taskModelProperties(for: kind, event: event) {
            emitter.capture(Self.taskModelEventName, properties)
            return
        }
        guard Self.mayObserve(event.code) else { return }
        let emitter = self.emitter
        state.enqueue(event) { observation in
            emitter.capture(Self.eventName, Self.properties(for: observation))
        }
    }

    public func flush() async {
        await state.drain()
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
        state.connectStarts = state.connectStarts.reduce(into: [:]) { result, entry in
            let retained = entry.value.filter { start in
                event.tNanos >= start.tNanos
                    && event.tNanos - start.tNanos <= Self.pendingStartLifetimeNanos
            }
            if !retained.isEmpty { result[entry.key] = retained }
        }
        state.readinessStarts = state.readinessStarts.filter { _, start in
            event.tNanos >= start.tNanos
                && event.tNanos - start.tNanos <= Self.pendingStartLifetimeNanos
        }
        state.hostAuthStarts = state.hostAuthStarts.filter { _, start in
            event.tNanos >= start.tNanos
                && event.tNanos - start.tNanos <= Self.pendingStartLifetimeNanos
        }
        let transport = Self.transport(for: event)
        switch event.code {
        case .connect:
            guard let surface = event.surface else { return nil }
            Self.storeConnectStart(
                Start(tNanos: event.tNanos, transport: transport),
                surface: surface,
                state: &state
            )
            return nil

        case .pairOk, .pairFail, .pairUnreachable:
            let start = Self.takeUniqueConnectStart(surface: event.surface, state: &state)
            if event.code == .pairOk, let surface = event.surface {
                Self.storeReadinessStart(
                    Start(tNanos: event.tNanos, transport: transport ?? start?.transport),
                    surface: surface,
                    state: &state
                )
            }
            return Self.terminal(
                phase: .pairing,
                event: event,
                start: start,
                transport: transport,
                userUsable: event.code == .pairOk
            )

        case .transportDialStarted:
            guard let correlation = Self.correlation(event.c) else { return nil }
            Self.storeStart(Start(
                tNanos: event.tNanos,
                transport: transport
            ), for: Key(
                phase: .transportDial,
                correlation: correlation
            ), state: &state)
            return nil

        case .transportDialConnected, .transportDialFailed, .transportDialCancelled:
            let key = Key(
                phase: .transportDial,
                correlation: Self.correlation(event.c)
            )
            let start = state.starts.removeValue(forKey: key)
            if event.code == .transportDialConnected {
                guard let surface = event.surface else {
                    return Self.terminal(
                        phase: .transportDial,
                        event: event,
                        start: start,
                        transport: transport ?? start?.transport,
                        userUsable: false
                    )
                }
                Self.storeHostAuthStart(Start(
                    tNanos: event.tNanos,
                    transport: transport ?? start?.transport
                ), surface: surface, state: &state)
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

        case .rpcReady, .rpcFailed:
            let start = state.readinessStarts.removeValue(forKey: event.surface)
                ?? Self.takeUniqueConnectStart(surface: event.surface, state: &state)
            return Self.terminal(
                phase: .rpcReady,
                event: event,
                start: start,
                transport: transport ?? start?.transport,
                userUsable: event.code == .rpcReady
            )

        case .recoveryStarted:
            guard let surface = event.surface else { return nil }
            Self.storeStart(Start(
                tNanos: event.tNanos,
                transport: transport
            ), for: Key(
                phase: .recovery,
                correlation: surface
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

    private static func storeConnectStart(
        _ start: Start,
        surface: UInt32?,
        state: inout State
    ) {
        if state.connectStarts[surface] == nil,
           state.connectStarts.count >= Self.maxPendingCorrelationKeys,
           let oldest = state.connectStarts.min(by: { lhs, rhs in
               (lhs.value.map(\.tNanos).min() ?? .max)
                   < (rhs.value.map(\.tNanos).min() ?? .max)
           })?.key {
            state.connectStarts.removeValue(forKey: oldest)
        }
        var starts = state.connectStarts[surface, default: []]
        appendBounded(start, to: &starts)
        state.connectStarts[surface] = starts
    }

    private static func takeUniqueConnectStart(
        surface: UInt32?,
        state: inout State
    ) -> Start? {
        guard let starts = state.connectStarts.removeValue(forKey: surface), starts.count == 1 else {
            return nil
        }
        return starts[0]
    }

    private static func storeReadinessStart(
        _ start: Start,
        surface: UInt32,
        state: inout State
    ) {
        if state.readinessStarts[surface] == nil,
           state.readinessStarts.count >= Self.maxPendingCorrelationKeys,
           let oldest = state.readinessStarts.min(by: { $0.value.tNanos < $1.value.tNanos })?.key {
            state.readinessStarts.removeValue(forKey: oldest)
        }
        state.readinessStarts[surface] = start
    }

    private static func storeHostAuthStart(
        _ start: Start,
        surface: UInt32?,
        state: inout State
    ) {
        if state.hostAuthStarts[surface] == nil,
           state.hostAuthStarts.count >= Self.maxPendingCorrelationKeys,
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
            userUsable: userUsable,
            event: event
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

    private static func mayObserve(_ code: DiagnosticEventCode) -> Bool {
        switch code {
        case .connect, .pairOk, .pairFail, .pairUnreachable,
             .transportDialStarted, .transportDialConnected, .transportDialFailed,
             .transportDialCancelled, .hostAuthenticated, .hostAuthenticationFailed,
             .rpcReady, .rpcFailed, .recoveryStarted, .recoverySucceeded, .recoveryFailed,
             .endpointStarting, .endpointActive, .endpointFailed,
             .relayPolicyRefreshStarted, .relayPolicyRefreshSucceeded,
             .relayPolicyRefreshFailed,
             .discoverySucceeded, .discoveryFailed:
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
        properties["event_code"] = .string(presentation.name(observation.event.code))
        properties["event_code_raw"] = .int(Int(observation.event.code.rawValue))
        if let surface = observation.event.surface,
           Int(surface) >= 0,
           Int(surface) <= Int(UInt32.max) {
            properties["event_surface"] = .int(Int(surface))
        }
        // Bound diagnostic slots before they leave the client.
        for (key, slot) in [
            ("event_a", observation.event.a),
            ("event_b", observation.event.b),
            ("event_c", observation.event.c),
        ] {
            guard let slot, slot >= 0, slot <= Int(UInt32.max) else { continue }
            properties[key] = .int(slot)
        }
        if observation.event.code == .transportDialCancelled,
           let rawReason = observation.event.a,
           let reason = DiagnosticCancellationReason(rawValue: rawReason) {
            properties["cancellation_reason"] = .string(String(describing: reason))
        }
        return properties
    }

    private static func phase(for code: DiagnosticEventCode) -> Phase? {
        switch code {
        case .transportDialConnected, .transportDialFailed, .transportDialCancelled:
            .transportDial
        case .hostAuthenticated, .hostAuthenticationFailed:
            .hostAuth
        case .rpcReady, .rpcFailed:
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
