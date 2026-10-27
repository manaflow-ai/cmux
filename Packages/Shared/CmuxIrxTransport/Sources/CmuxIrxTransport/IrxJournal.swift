import CmuxSafeConcurrency
public import Foundation
import OSLog

/// One journaled transport event. Every state transition, dial attempt,
/// admission, credential movement, keepalive exchange, and close is recorded
/// with both wall and monotonic timestamps so the soak analyzer can time
/// recoveries from the app's own clock.
public struct IrxJournalEvent: Sendable {
    public var wallTime: Date
    public var monotonicMs: UInt64
    public var component: String
    public var event: String
    public var attributes: [String: String]

    public init(
        wallTime: Date,
        monotonicMs: UInt64,
        component: String,
        event: String,
        attributes: [String: String]
    ) {
        self.wallTime = wallTime
        self.monotonicMs = monotonicMs
        self.component = component
        self.event = event
        self.attributes = attributes
    }

    /// Returns the event representation safe for diagnostic retention and output.
    func redacted() -> Self {
        var result = self
        // Also catches keys embedded in native error descriptions, not just named fields.
        result.attributes = attributes.mapValues {
            $0.replacingOccurrences(of: "(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])",
                with: "<redacted-endpoint>", options: .regularExpression)
        }
        return result
    }
}

/// Structured transport journal: every event goes to os.Logger at NOTICE
/// level (notice persists in `log show` where info does not) and, when a
/// journal URL is configured, to an append-only JSONL file the soak analyzer
/// consumes directly. Also keeps a bounded in-memory ring for the diag verb.
public final class IrxJournal: Sendable {
    public static let ringCapacity = 512

    /// The ring, the counters and the terminal-trace rate window.
    private struct State: Sendable {
        var ring: [IrxJournalEvent] = []
        var counters: [String: Int] = [:]
        var terminalTraceWindowInitialized = false
        var terminalTraceWindowStartMs: UInt64 = 0
        var terminalTraceEventsInWindow = 0
    }

    /// The append-only JSONL file this journal writes, when one was configured.
    public let fileURL: URL?
    private let logger: Logger
    private let state = Mutex(State())
    private let startedAt = DispatchTime.now()
    /// Opened `O_APPEND`, so each line's single `write(2)` lands whole at the
    /// end of the file; concurrent records need no lock around the write.
    private let fileHandle: FileHandle?
    private static let terminalTraceEventsPerMinute = 120
    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public init(subsystem: String, category: String, journalFileURL: URL? = nil) {
        logger = Logger(subsystem: subsystem, category: category)
        fileURL = journalFileURL
        fileHandle = journalFileURL.flatMap(IrxJournal.openAppending)
    }

    private static func openAppending(_ journalFileURL: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(
            at: journalFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = journalFileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Records one event. `attributes` values must already be privacy-safe:
    /// identifiers and codes, never payload content. Full endpoint keys are
    /// redacted before reaching the diagnostic ring, system log or journal file.
    public func record(
        _ component: String,
        _ event: String,
        _ attributes: [String: String] = [:]
    ) {
        let monotonicMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        if component == "terminal-trace" {
            let admitted: Bool = state.withLock { state in
                if !state.terminalTraceWindowInitialized
                    || monotonicMs < state.terminalTraceWindowStartMs
                    || monotonicMs - state.terminalTraceWindowStartMs >= 60_000 {
                    state.terminalTraceWindowInitialized = true
                    state.terminalTraceWindowStartMs = monotonicMs
                    state.terminalTraceEventsInWindow = 0
                }
                guard state.terminalTraceEventsInWindow < Self.terminalTraceEventsPerMinute else {
                    state.counters["terminal_trace_dropped", default: 0] += 1
                    return false
                }
                state.terminalTraceEventsInWindow += 1
                return true
            }
            guard admitted else { return }
        }
        let entry = IrxJournalEvent(
            wallTime: Date(),
            monotonicMs: monotonicMs,
            component: component,
            event: event,
            attributes: attributes
        ).redacted()
        let rendered = Self.render(entry)
        logger.notice("irx \(rendered, privacy: .public)")
        state.withLock { state in
            state.counters[event, default: 0] += 1
            state.ring.append(entry)
            if state.ring.count > Self.ringCapacity {
                state.ring.removeFirst(state.ring.count - Self.ringCapacity)
            }
        }
        try? fileHandle?.write(contentsOf: Data((rendered + "\n").utf8))
    }

    /// Counter snapshot for diagnostics (dials, admissions, denials by code,
    /// rotations, pings, closes by reason).
    public func counterSnapshot() -> [String: Int] {
        state.withLock { $0.counters }
    }

    /// The newest events, oldest first, for the diag socket verb.
    public func tail(_ count: Int = 100) -> [IrxJournalEvent] {
        state.withLock { Array($0.ring.suffix(count)) }
    }

    public static func render(_ entry: IrxJournalEvent) -> String {
        var object: [String: Any] = [
            "ts": isoTimestamp(entry.wallTime),
            "mono_ms": entry.monotonicMs,
            "component": entry.component,
            "event": entry.event,
        ]
        for (key, value) in entry.redacted().attributes {
            object["a_" + key] = value
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"event\":\"journal-render-failed\"}"
        }
        return text
    }

}
