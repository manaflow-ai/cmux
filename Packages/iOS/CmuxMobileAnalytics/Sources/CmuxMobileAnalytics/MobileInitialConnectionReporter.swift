public import CMUXMobileCore
internal import Foundation

/// The user-visible population for one app-open connection attempt.
public enum MobileInitialConnectionPopulation: String, Sendable, Codable, CaseIterable {
    case coldOpen = "cold_open"
    case warmOpen = "warm_open"
    case reconnect
    case pairingRequired = "pairing_required"
}

/// Correlates app lifecycle, connection, pairing, RPC, and terminal-surface
/// diagnostics into one launch-to-first-working-terminal observation.
///
/// The diagnostic ring is the source of truth for lifecycle edges. This keeps
/// the tracker independent of the shell's many connection entry points and
/// means retries update one in-flight attempt instead of producing a new row.
/// An attempt completes only after both RPC readiness and a mounted terminal
/// output consumer are present. A bounded timer emits a timeout when neither
/// condition is reached.
public final class MobileInitialConnectionReporter: Sendable {
    public static let operationalEventName = MobileNetworkOutcomeReporter.eventName
    public static let productEventName = "ios_initial_connection"
    public static let phase = "initial_connect"
    public static let defaultTimeout: Duration = .seconds(60)

    private struct Attempt: Sendable {
        let id: UUID
        let startedAtNanos: UInt64
        var population: MobileInitialConnectionPopulation
        var transport: DiagnosticTransportKind?
        var failure: DiagnosticFailureKind?
        var rpcReady = false
        var terminalReady = false
    }

    private enum Outcome: String, Sendable {
        case success
        case failure
        case timeout
        case abandoned
    }

    private struct Observation: Sendable {
        let attemptID: UUID
        let population: MobileInitialConnectionPopulation
        let outcome: Outcome
        let durationMs: UInt32
        let transport: DiagnosticTransportKind?
        let failure: DiagnosticFailureKind?
        let terminalReady: Bool
    }

    private struct State: Sendable {
        var active: Attempt?
        var hasForegrounded = false
        var isForeground = true
        var isConnected = false
        var hasEverConnected = false
        var terminalReady = false
        var rpcReady = false
    }

    private final class StateStore: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.cmux.mobile-initial-connection")
        private let timeout: Duration
        private let timeoutNanos: UInt64
        private let now: @Sendable () -> UInt64
        private let emit: @Sendable (Observation) -> Void
        private var state = State()
        private var timeoutTask: Task<Void, Never>?

        init(
            timeout: Duration,
            now: @escaping @Sendable () -> UInt64,
            emit: @escaping @Sendable (Observation) -> Void
        ) {
            self.timeout = timeout
            self.timeoutNanos = Self.nanoseconds(timeout)
            self.now = now
            self.emit = emit
        }

        deinit {
            timeoutTask?.cancel()
        }

        func enqueue(_ event: DiagnosticEvent) {
            queue.async { [self] in
                process(event)
            }
        }

        func drain() async {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume()
                }
            }
        }

        private func process(_ event: DiagnosticEvent) {
            expireIfNeeded(at: event.tNanos)

            if event.code == .appFeatureAction,
               let kind = event.a.flatMap(DiagnosticAppEventKind.init(rawValue:)) {
                processAppEvent(kind, event: event)
                return
            }

            switch event.code {
            case .rpcReady:
                state.rpcReady = true
                state.isConnected = true
                state.hasEverConnected = true
                if let transport = DiagnosticEventPresentation().transportKind(of: event) {
                    state.active?.transport = transport
                }
                finishIfReady(at: event.tNanos)

            case .rpcFailed:
                state.rpcReady = false
                state.active?.failure = DiagnosticEventPresentation().failureKind(of: event)

            case .recoveryStarted:
                state.rpcReady = false
                state.active?.population = .reconnect
                startIfNeeded(.reconnect, at: event.tNanos)

            case .recoverySucceeded:
                state.isConnected = true
                state.hasEverConnected = true
                state.rpcReady = true
                finishIfReady(at: event.tNanos)

            case .recoveryFailed:
                state.rpcReady = false
                state.active?.failure = DiagnosticEventPresentation().failureKind(of: event)

            case .sessionClosed, .routeUnavailable, .admissionFailed,
                 .hostAuthenticationFailed, .transportDialFailed,
                 .transportDialCancelled:
                state.rpcReady = false
                state.active?.failure = DiagnosticEventPresentation().failureKind(of: event)

            default:
                break
            }
        }

        private func processAppEvent(
            _ kind: DiagnosticAppEventKind,
            event: DiagnosticEvent
        ) {
            switch kind {
            case .appForegrounded:
                if state.active != nil {
                    // The app scene and root view can both report the same
                    // active transition. Keep the in-flight attempt so this
                    // duplicate callback cannot manufacture an abandoned row
                    // or reset the launch-to-terminal clock.
                    state.isForeground = true
                    return
                }
                let population: MobileInitialConnectionPopulation
                if state.hasEverConnected && !state.isConnected {
                    population = .reconnect
                } else if state.hasForegrounded {
                    population = .warmOpen
                } else {
                    population = .coldOpen
                }
                state.isForeground = true
                state.hasForegrounded = true
                startIfNeeded(population, at: event.tNanos)
                finishIfReady(at: event.tNanos)

            case .appBackgrounded:
                state.isForeground = false
                if state.active != nil {
                    finish(
                        at: event.tNanos,
                        outcome: .abandoned,
                        terminalReady: false
                    )
                }

            case .connectionStateChanged:
                let connected = event.c == 1
                state.isConnected = connected
                state.rpcReady = connected && state.rpcReady
                if connected {
                    state.hasEverConnected = true
                    finishIfReady(at: event.tNanos)
                } else {
                    state.rpcReady = false
                    state.active?.failure = .connectionClosed
                    if state.isForeground && state.hasEverConnected {
                        startIfNeeded(.reconnect, at: event.tNanos)
                    }
                }

            case .pairingStarted:
                if state.active == nil {
                    startIfNeeded(.pairingRequired, at: event.tNanos)
                } else {
                    state.active?.population = .pairingRequired
                }

            case .pairingFailed:
                state.active?.failure = DiagnosticEventPresentation().failureKind(of: event)

            case .reconnectStarted:
                startIfNeeded(.reconnect, at: event.tNanos)
                state.active?.population = .reconnect

            case .reconnectFailed:
                state.active?.failure = DiagnosticEventPresentation().failureKind(of: event)

            case .foregroundTransportSelected:
                if let raw = event.c, let transport = DiagnosticTransportKind(rawValue: raw) {
                    state.active?.transport = transport
                }

            case .terminalOutputReceived:
                state.terminalReady = true
                state.active?.terminalReady = true
                finishIfReady(at: event.tNanos)

            case .terminalUnmounted:
                state.terminalReady = false
                state.active?.terminalReady = false

            default:
                break
            }
        }

        private func startIfNeeded(
            _ population: MobileInitialConnectionPopulation,
            at timestamp: UInt64
        ) {
            guard state.active == nil else { return }
            let id = UUID()
            state.active = Attempt(
                id: id,
                startedAtNanos: timestamp,
                population: population,
                transport: nil,
                failure: nil,
                rpcReady: state.rpcReady,
                terminalReady: state.terminalReady
            )
            armTimeout(for: id)
        }

        private func finishIfReady(at timestamp: UInt64) {
            guard let attempt = state.active,
                  state.isConnected,
                  (attempt.rpcReady || state.rpcReady),
                  (attempt.terminalReady || state.terminalReady)
            else { return }
            finish(at: timestamp, outcome: .success, terminalReady: true)
        }

        private func finish(
            at timestamp: UInt64,
            outcome: Outcome,
            terminalReady: Bool
        ) {
            guard let attempt = state.active else { return }
            let elapsed = timestamp >= attempt.startedAtNanos
                ? timestamp - attempt.startedAtNanos
                : 0
            let observation = Observation(
                attemptID: attempt.id,
                population: attempt.population,
                outcome: outcome,
                durationMs: UInt32(clamping: Int(elapsed / 1_000_000)),
                transport: attempt.transport,
                failure: attempt.failure ?? (outcome == .timeout ? .timedOut : outcome == .abandoned ? .cancelled : nil),
                terminalReady: terminalReady
            )
            state.active = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            emit(observation)
        }

        private func expireIfNeeded(at timestamp: UInt64) {
            guard let attempt = state.active,
                  timestamp >= attempt.startedAtNanos,
                  timestamp - attempt.startedAtNanos >= timeoutNanos
            else { return }
            finish(at: timestamp, outcome: .timeout, terminalReady: false)
        }

        private func armTimeout(for id: UUID) {
            timeoutTask?.cancel()
            let timeout = self.timeout
            timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.queue.async { [weak self] in
                    guard let self, self.state.active?.id == id else { return }
                    self.finish(
                        at: max(self.now(), self.state.active?.startedAtNanos ?? self.now()),
                        outcome: .timeout,
                        terminalReady: false
                    )
                }
            }
        }

        private static func nanoseconds(_ duration: Duration) -> UInt64 {
            let components = duration.components
            let seconds = UInt64(max(0, components.seconds))
            let attoseconds = UInt64(max(0, components.attoseconds))
            return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
        }
    }

    private let state: StateStore
    private let productEmitter: any AnalyticsEmitting
    private let operationalEmitter: any AnalyticsEmitting

    /// Creates the tracker with separate PostHog and Axiom destinations.
    public init(
        productEmitter: any AnalyticsEmitting,
        operationalEmitter: any AnalyticsEmitting,
        timeout: Duration = .seconds(60),
        now: (@Sendable () -> UInt64)? = nil
    ) {
        self.productEmitter = productEmitter
        self.operationalEmitter = operationalEmitter
        self.state = StateStore(
            timeout: max(.milliseconds(1), timeout),
            now: now ?? { DispatchTime.now().uptimeNanoseconds },
            emit: { [productEmitter, operationalEmitter] observation in
                let properties = Self.properties(for: observation)
                productEmitter.capture(Self.productEventName, properties)
                operationalEmitter.capture(Self.operationalEventName, properties)
            }
        )
    }

    /// Convenience initializer for callers that intentionally use one sink.
    public convenience init(
        emitter: any AnalyticsEmitting,
        timeout: Duration = .seconds(60),
        now: (@Sendable () -> UInt64)? = nil
    ) {
        self.init(
            productEmitter: emitter,
            operationalEmitter: emitter,
            timeout: timeout,
            now: now
        )
    }

    /// Queues a diagnostic event without blocking the diagnostic event tap.
    public func ingest(_ event: DiagnosticEvent) {
        state.enqueue(event)
    }

    /// Drains the tracker and both analytics destinations.
    public func flush() async {
        await state.drain()
        await productEmitter.flush()
        await operationalEmitter.flush()
    }

    private static func properties(for observation: Observation) -> [String: AnalyticsValue] {
        var properties: [String: AnalyticsValue] = [
            "phase": .string(Self.phase),
            "population": .string(observation.population.rawValue),
            "attempt_id": .string(observation.attemptID.uuidString),
            "outcome": .string(observation.outcome.rawValue),
            "duration_ms": .int(Int(observation.durationMs)),
            "user_usable": .bool(observation.outcome == .success),
            "terminal_ready": .bool(observation.terminalReady),
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
}
