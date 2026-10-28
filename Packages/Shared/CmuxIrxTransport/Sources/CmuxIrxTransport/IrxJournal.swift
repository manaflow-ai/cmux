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

    /// The append-only JSONL file this journal writes: the configured one,
    /// or nil when none was configured or it could not be opened safely
    /// (``openPrivateAppending(_:)``).
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
        let handle = journalFileURL.flatMap(IrxJournal.openPrivateAppending)
        fileHandle = handle
        fileURL = handle == nil ? nil : journalFileURL
    }

    /// Opens the journal for appending, readable and writable only by this
    /// user, or returns nil (the journal then keeps only its ring and the
    /// system log). The journal holds session identifiers, and its path may
    /// be predictable, so:
    /// - its directory must belong to this user and be writable by no one
    ///   else (another user cannot swap the file between checks);
    /// - the last path component is never followed (`O_NOFOLLOW`): a link
    ///   planted in its place is refused, not written through;
    /// - the file is created `0600`, or an existing one must be a regular file
    ///   of this user with one link (no hard link to another file), and is
    ///   set to `0600`.
    static func openPrivateAppending(_ journalFileURL: URL) -> FileHandle? {
        let directory = journalFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isPrivateDirectory(directory) else { return nil }
        let descriptor = journalFileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let flags = O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW
            let created = open(path, flags | O_CREAT | O_EXCL, 0o600)
            if created >= 0 || errno != EEXIST { return created }
            return open(path, flags)
        }
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, fchmod(descriptor, 0o600) == 0 else {
            close(descriptor)
            return nil
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// A directory (not a link) of this user that no other user can write.
    private static func isPrivateDirectory(_ directory: URL) -> Bool {
        directory.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            var info = stat()
            return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid()
                && info.st_mode & (S_IWGRP | S_IWOTH) == 0
        }
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
