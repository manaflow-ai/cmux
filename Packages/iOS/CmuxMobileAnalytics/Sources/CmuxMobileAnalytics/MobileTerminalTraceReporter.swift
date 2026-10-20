public import CMUXMobileCore
internal import Foundation

/// Emits a bounded Axiom summary for slow or failed terminal operations.
///
/// Every phase remains in the local diagnostic ring (subject to its own
/// admission cap). Axiom receives only one summary per operation when it is
/// slow enough to explain a user-visible stall, or when it fails.
public final class MobileTerminalTraceReporter: Sendable {
    public static let eventName = "ios_connectivity_latency"
    private static let tracePhase = "terminal_trace"
    private static let slowThresholdMilliseconds: UInt32 = 1_000
    private static let pendingLifetimeNanos: UInt64 = 5 * 60 * 1_000_000_000
    private static let maxPendingTraces = 64
    private static let maxEventsPerMinute = 30

    private struct Start: Sendable {
        let operation: DiagnosticTerminalTraceOperation
        let tNanos: UInt64
        let replayContext: MobileTerminalReplayTraceContext?
        /// Background-transition count when this operation began.
        let backgroundEpoch: UInt64
    }

    private struct State: Sendable {
        var starts: [UInt64: Start] = [:]
        var windowStart: UInt64 = 0
        var emittedInWindow = 0
        /// Counts transitions out of the foreground.
        ///
        /// Comparing this against the value recorded at `started` answers the
        /// question the flag below cannot: an operation that began on screen,
        /// spent an hour suspended and settled after reactivation is in the
        /// foreground when it reports, but its elapsed time is not screen
        /// time. Only an unchanged count means the whole trace was on screen.
        var backgroundEpoch: UInt64 = 0
        /// Whether the app was in the foreground when the phase was recorded.
        ///
        /// A suspended app runs no code, so an operation that spans
        /// suspension accrues wall-clock time it never spent waiting on
        /// screen. Without this flag a stall of a few foreground seconds and
        /// one that sat in a pocket for an hour are indistinguishable in
        /// Axiom, and any percentile over the mix is meaningless.
        var isForeground = true
    }

    private final class StateStore: @unchecked Sendable {
        // Carve-out: ordered diagnostic callback delivery; the producer cannot suspend.
        private let queue = DispatchQueue(label: "com.cmux.mobile-terminal-traces")
        // Carve-out: nonblocking admission bounds synchronous event-tap work before it is queued.
        private let permits = DispatchSemaphore(value: 128)
        private var state = State()

        deinit {}

        func enqueue(
            _ event: DiagnosticEvent,
            emit: @escaping @Sendable (Observation) -> Void
        ) {
            guard permits.wait(timeout: .now()) == .success else { return }
            queue.async { [self] in
                defer { permits.signal() }
                guard let observation = MobileTerminalTraceReporter.observe(event, state: &state) else { return }
                emit(observation)
            }
        }

        func setForeground(_ active: Bool) {
            queue.async { [self] in
                if !active, state.isForeground { state.backgroundEpoch &+= 1 }
                state.isForeground = active
            }
        }

        func drain() async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
    }

    private struct Observation: Sendable {
        let traceID: DiagnosticTerminalTraceID
        let operation: DiagnosticTerminalTraceOperation
        let terminalPhase: DiagnosticTerminalTracePhase
        let durationMilliseconds: UInt32
        let outcome: String
        let replayContext: MobileTerminalReplayTraceContext?
        let isForeground: Bool
    }

    private let emitter: any AnalyticsEmitting
    private let state = StateStore()

    public init(emitter: any AnalyticsEmitting) {
        self.emitter = emitter
    }

    deinit {}

    /// Queues one trace phase without blocking the diagnostic event tap.
    public func ingest(_ event: DiagnosticEvent) {
        guard event.code == .terminalTrace, event.traceID != nil else { return }
        let emitter = self.emitter
        state.enqueue(event) { observation in
            emitter.capture(Self.eventName, Self.properties(for: observation))
        }
    }

    /// Records the app lifecycle edge so each emitted row says whether its
    /// elapsed time was spent on screen.
    public func setForeground(_ active: Bool) {
        state.setForeground(active)
    }

    public func flush() async {
        await state.drain()
        await emitter.flush()
    }

    private static func observe(
        _ event: DiagnosticEvent,
        state: inout State
    ) -> Observation? {
        guard let traceID = event.traceID.flatMap(DiagnosticTerminalTraceID.init(rawValue:)),
              let operation = event.a.flatMap(DiagnosticTerminalTraceOperation.init(rawValue:)),
              let phase = event.b.flatMap(DiagnosticTerminalTracePhase.init(rawValue:)) else {
            return nil
        }
        state.starts = state.starts.filter { _, start in
            event.tNanos >= start.tNanos
                && event.tNanos - start.tNanos <= pendingLifetimeNanos
        }
        if phase == .started {
            if state.starts[traceID.rawValue] == nil,
               state.starts.count >= maxPendingTraces,
               let oldest = state.starts.min(by: { $0.value.tNanos < $1.value.tNanos })?.key {
                state.starts.removeValue(forKey: oldest)
            }
            state.starts[traceID.rawValue] = Start(
                operation: operation,
                tNanos: event.tNanos,
                replayContext: event.c.flatMap(MobileTerminalReplayTraceContext.init(encoded:)),
                backgroundEpoch: state.backgroundEpoch
            )
            return nil
        }
        // A stall report is the only non-terminal emission: the operation is
        // still outstanding, so the pending start must survive for the phase
        // that eventually settles it. Without this an operation that never
        // settles produced no row at all.
        if phase == .stalled {
            guard let duration = event.ms else { return nil }
            guard admitEmission(at: event.tNanos, state: &state) else { return nil }
            let start = state.starts[traceID.rawValue]
            return Observation(
                traceID: traceID,
                operation: start?.operation ?? operation,
                terminalPhase: phase,
                durationMilliseconds: duration,
                outcome: "stalled",
                replayContext: event.c.flatMap(MobileTerminalReplayTraceContext.init(encoded:))
                    ?? start?.replayContext,
                isForeground: stayedForeground(start, state: state)
            )
        }
        guard phase == .applied || phase == .failed || phase == .discarded else { return nil }
        let start = state.starts.removeValue(forKey: traceID.rawValue)
        // Prefer the monotonic diagnostic timestamps whenever the start phase
        // survived admission. The measured `ms` is only a fallback for a
        // start that was dropped under pressure, avoiding wall-clock jumps in
        // normal traces.
        let duration = start.map {
            UInt32(clamping: Int(max(0, event.tNanos - $0.tNanos) / 1_000_000))
        } ?? event.ms
        guard let duration else { return nil }
        let outcome = phase == .applied ? "success" : phase == .discarded ? "cancelled" : "failure"
        guard duration >= slowThresholdMilliseconds || outcome != "success" else { return nil }
        guard admitEmission(at: event.tNanos, state: &state) else { return nil }
        return Observation(
            traceID: traceID,
            operation: start?.operation ?? operation,
            terminalPhase: phase,
            durationMilliseconds: duration,
            outcome: outcome,
            replayContext: start?.replayContext,
            isForeground: stayedForeground(start, state: state)
        )
    }

    /// Whether the whole operation stayed on screen.
    ///
    /// Conservative when the start was dropped under admission pressure: an
    /// operation whose beginning is unknown cannot claim its elapsed time was
    /// screen time.
    private static func stayedForeground(_ start: Start?, state: State) -> Bool {
        guard let start else { return false }
        return state.isForeground && start.backgroundEpoch == state.backgroundEpoch
    }

    private static func admitEmission(at now: UInt64, state: inout State) -> Bool {
        if state.windowStart == 0 || now < state.windowStart
            || now - state.windowStart >= 60 * 1_000_000_000 {
            state.windowStart = now
            state.emittedInWindow = 0
        }
        guard state.emittedInWindow < maxEventsPerMinute else { return false }
        state.emittedInWindow += 1
        return true
    }

    private static func properties(for observation: Observation) -> [String: AnalyticsValue] {
        var properties: [String: AnalyticsValue] = [
            "phase": .string(tracePhase),
            "outcome": .string(observation.outcome),
            "duration_ms": .int(Int(observation.durationMilliseconds)),
            "user_usable": .bool(false),
            "trace_id": .string(observation.traceID.stringValue),
            "operation": .string(String(describing: observation.operation)),
            "terminal_phase": .string(String(describing: observation.terminalPhase)),
            "app_foreground": .bool(observation.isForeground),
        ]
        if let context = observation.replayContext {
            properties["replay_trigger"] = .string(String(describing: context.trigger))
            // The field that separates a blank terminal from a stale one.
            properties["surface_blank"] = .bool(context.surfaceIsBlank)
            properties["barrier_active"] = .bool(context.barrierActive)
            properties["replay_attempt"] = .int(context.attempt)
        }
        return properties
    }
}
