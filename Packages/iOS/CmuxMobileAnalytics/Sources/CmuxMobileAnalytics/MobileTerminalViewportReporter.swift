public import CMUXMobileCore
internal import Foundation

/// Emits bounded Axiom evidence for terminal viewport negotiations.
///
/// The surface records one row when it publishes a logical grid. This reporter
/// keeps only a small per-surface history, marks repeated publication of the
/// same grid inside a short window as a loop candidate, and drops events past
/// a per-minute cap. No terminal content, commands, workspace names, or raw
/// surface identifiers enter the payload.
public final class MobileTerminalViewportReporter: Sendable {
    /// The Axiom event name for terminal viewport diagnostics.
    public static let eventName = "ios_terminal_viewport_resize"

    private static let repeatedCapacityWindowNanos: UInt64 = 10 * 1_000_000_000
    private static let loopCandidateThreshold = 4
    private static let anomalyCooldownNanos: UInt64 = 60 * 1_000_000_000
    private static let maximumSurfaceStates = 64
    private static let maximumEventsPerMinute = 60
    private static let maximumColumns = 512
    private static let maximumRows = 512

    private struct Episode: Sendable {
        let columns: Int
        let rows: Int
        let firstReportNanos: UInt64
        var lastReportNanos: UInt64
        var sameCapacityReports: Int
        var lastAnomalyNanos: UInt64?
    }

    private struct State: Sendable {
        var episodes: [UInt32: Episode] = [:]
        var windowStartNanos: UInt64 = 0
        var emittedInWindow = 0
    }

    private final class StateStore: @unchecked Sendable {
        // Carve-out: ordered diagnostic callback delivery; the producer cannot suspend.
        private let queue = DispatchQueue(label: "com.cmux.mobile-terminal-viewport")
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
                guard let observation = MobileTerminalViewportReporter.observe(
                    event,
                    state: &state
                ) else { return }
                emit(observation)
            }
        }

        func drain() async {
            await withCheckedContinuation { continuation in
                queue.async { continuation.resume() }
            }
        }
    }

    private struct Observation: Sendable {
        let surface: UInt32
        let columns: Int
        let rows: Int
        let reportID: UInt64
        let sameCapacityReports: Int
        let repeatWindowMilliseconds: Int
        let loopDetected: Bool
    }

    private let emitter: any AnalyticsEmitting
    private let state = StateStore()

    /// Creates a viewport reporter backed by the authenticated operational
    /// analytics emitter.
    ///
    /// - Parameter emitter: The injected emitter that posts to Axiom.
    public init(emitter: any AnalyticsEmitting) {
        self.emitter = emitter
    }

    deinit {}

    /// Queues one published logical-grid report without blocking layout.
    public func ingest(_ event: DiagnosticEvent) {
        guard event.code == .appFeatureAction,
              event.a == DiagnosticAppEventKind.terminalViewportReportPublished.rawValue else {
            return
        }
        let emitter = self.emitter
        state.enqueue(event) { observation in
            emitter.capture(Self.eventName, Self.properties(for: observation))
        }
    }

    /// Drains queued observations and pending Axiom uploads.
    public func flush() async {
        await state.drain()
        await emitter.flush()
    }

    private static func observe(
        _ event: DiagnosticEvent,
        state: inout State
    ) -> Observation? {
        guard let surface = event.surface,
              let columns = event.b,
              let rows = event.c,
              let reportID = event.sequence,
              reportID > 0,
              (1...maximumColumns).contains(columns),
              (1...maximumRows).contains(rows) else {
            return nil
        }

        state.episodes = state.episodes.filter { _, episode in
            event.tNanos >= episode.lastReportNanos
                && event.tNanos - episode.lastReportNanos <= repeatedCapacityWindowNanos
        }
        let key = surface
        if state.episodes[key] == nil,
           state.episodes.count >= maximumSurfaceStates,
           let oldest = state.episodes.min(by: {
               $0.value.lastReportNanos < $1.value.lastReportNanos
           })?.key {
            state.episodes.removeValue(forKey: oldest)
        }

        var episode: Episode
        if let previous = state.episodes[key],
           previous.columns == columns,
           previous.rows == rows,
           event.tNanos >= previous.lastReportNanos,
           event.tNanos - previous.lastReportNanos <= repeatedCapacityWindowNanos {
            episode = previous
            episode.lastReportNanos = event.tNanos
            episode.sameCapacityReports += 1
        } else {
            episode = Episode(
                columns: columns,
                rows: rows,
                firstReportNanos: event.tNanos,
                lastReportNanos: event.tNanos,
                sameCapacityReports: 1,
                lastAnomalyNanos: nil
            )
        }

        var loopDetected = false
        if episode.sameCapacityReports >= loopCandidateThreshold {
            let canReport = episode.lastAnomalyNanos.map {
                event.tNanos >= $0
                    && event.tNanos - $0 >= anomalyCooldownNanos
            } ?? true
            if canReport {
                episode.lastAnomalyNanos = event.tNanos
                loopDetected = true
            }
        }
        state.episodes[key] = episode

        guard admitEmission(at: event.tNanos, state: &state) else { return nil }
        return Observation(
            surface: surface,
            columns: columns,
            rows: rows,
            reportID: reportID,
            sameCapacityReports: episode.sameCapacityReports,
            repeatWindowMilliseconds: Int(
                min(
                    UInt64(Int.max),
                    (event.tNanos - episode.firstReportNanos) / 1_000_000
                )
            ),
            loopDetected: loopDetected
        )
    }

    private static func admitEmission(at now: UInt64, state: inout State) -> Bool {
        if state.windowStartNanos == 0
            || now < state.windowStartNanos
            || now - state.windowStartNanos >= 60 * 1_000_000_000 {
            state.windowStartNanos = now
            state.emittedInWindow = 0
        }
        guard state.emittedInWindow < maximumEventsPerMinute else { return false }
        state.emittedInWindow += 1
        return true
    }

    private static func properties(for observation: Observation) -> [String: AnalyticsValue] {
        [
            "phase": .string("terminal_viewport"),
            "status": .string("published"),
            "columns": .int(observation.columns),
            "rows": .int(observation.rows),
            "report_id": .int(Int(clamping: observation.reportID)),
            "event_surface": .int(Int(observation.surface)),
            "same_capacity_reports": .int(observation.sameCapacityReports),
            "repeat_window_ms": .int(observation.repeatWindowMilliseconds),
            "loop_detected": .bool(observation.loopDetected),
        ]
    }
}
