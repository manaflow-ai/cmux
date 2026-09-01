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
}

/// Structured transport journal: every event goes to os.Logger at NOTICE
/// level (notice persists in `log show` where info does not) and, when a
/// journal URL is configured, to an append-only JSONL file the soak analyzer
/// consumes directly. Also keeps a bounded in-memory ring for the diag verb.
public final class IrxJournal: @unchecked Sendable {
    public static let ringCapacity = 512

    private let logger: Logger
    private let lock = NSLock()
    private let startedAt = DispatchTime.now()
    private var fileHandle: FileHandle?
    private var ring: [IrxJournalEvent] = []
    private var counters: [String: Int] = [:]
    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public init(subsystem: String, category: String, journalFileURL: URL? = nil) {
        logger = Logger(subsystem: subsystem, category: category)
        if let journalFileURL {
            let manager = FileManager.default
            try? manager.createDirectory(
                at: journalFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !manager.fileExists(atPath: journalFileURL.path) {
                manager.createFile(atPath: journalFileURL.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: journalFileURL)
            _ = try? fileHandle?.seekToEnd()
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Records one event. `attributes` values must already be privacy-safe:
    /// identifiers and codes, never payload content.
    public func record(
        _ component: String,
        _ event: String,
        _ attributes: [String: String] = [:]
    ) {
        let monotonicMs =
            (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        let entry = IrxJournalEvent(
            wallTime: Date(),
            monotonicMs: monotonicMs,
            component: component,
            event: event,
            attributes: attributes
        )
        let rendered = Self.render(entry)
        logger.notice("irx \(rendered, privacy: .public)")
        lock.lock()
        counters[event, default: 0] += 1
        ring.append(entry)
        if ring.count > Self.ringCapacity {
            ring.removeFirst(ring.count - Self.ringCapacity)
        }
        if let fileHandle {
            try? fileHandle.write(contentsOf: Data((rendered + "\n").utf8))
        }
        lock.unlock()
    }

    /// Counter snapshot for diagnostics (dials, admissions, denials by code,
    /// rotations, pings, closes by reason).
    public func counterSnapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// The newest events, oldest first, for the diag socket verb.
    public func tail(_ count: Int = 100) -> [IrxJournalEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(ring.suffix(count))
    }

    public static func render(_ entry: IrxJournalEvent) -> String {
        var object: [String: Any] = [
            "ts": isoTimestamp(entry.wallTime),
            "mono_ms": entry.monotonicMs,
            "component": entry.component,
            "event": entry.event,
        ]
        for (key, value) in entry.attributes {
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
