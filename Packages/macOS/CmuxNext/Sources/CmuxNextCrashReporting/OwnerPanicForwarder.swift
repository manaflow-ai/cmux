public import Foundation
public import Sentry
import CmuxNextCompat
import os

/// Sends a cmux Rust process's panic log to Sentry (cx-urd.59).
///
/// The cmux-tui owner appends one JSON line per panic to
/// `owner-panics-<session>.jsonl` at its state root, and the acpmux daemon
/// to `$ACPMUX_HOME/panics.jsonl` (message, location, thread, backtrace;
/// the `cmux-panic-log` format). ``RustPanicSource`` labels each. This reads the lines added since the last read (a
/// byte offset kept in `stateFile`) and sends each as an event: a panic does
/// not always end the owner (worker threads, caught panics), so it is not a
/// crash report. The first run marks a log that exists read; a log that does
/// not exist yet is read from its first byte once a process creates it (the
/// Rust writers create theirs at their first record). Lines from a
/// time reports were off (`sends` false) are
/// marked read and never sent. Debug test panics (`"test": true`) are
/// skipped. The same reader sends a hang log (`owner-hangs-<session>.jsonl`,
/// `$ACPMUX_HOME/hangs.jsonl`): each `"event": "hang"` line is one warning,
/// at most one per fingerprint (source, scope, method) and
/// ``maxHangEventsPerDay`` in all per day, as Chrome throttles
/// `DumpWithoutCrashing` per location (base/debug/dump_without_crashing.h);
/// the rest are marked read and counted in the log.
/// No event carries a path or URL (``RustLogScrubber``, p10-stability-150).
public final class OwnerPanicForwarder: Sendable {
    struct State: Codable, Equatable {
        /// Bytes of the log already read.
        var offset: UInt64
        /// The log's file identity, so a recreated log is read from the start. 0: the log did not
        /// exist at the first run, so the log a process creates later is read from its first byte.
        var inode: UInt64
        /// The day (days since 1970, UTC) of ``sentHangs``.
        var hangDay: Int64?
        /// The hang fingerprints sent on ``hangDay``.
        var sentHangs: [String]?
    }

    /// The exception type of a hang event.
    static let hangType = "RustHang"
    /// The most hang events one log sends in a day.
    public static let maxHangEventsPerDay = 20

    private let log: URL
    private let stateFile: URL
    private let sends: Bool
    private let source: RustPanicSource
    private let capture: @Sendable (Event) -> Void
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.owner-panic-forwarder", qos: .utility)
    private let watcher = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    /// - Parameters:
    ///   - log: The panic log to read.
    ///   - stateFile: Where the read offset is kept (one per log).
    ///   - sends: The user's telemetry choice; false marks lines read without sending.
    ///   - source: Which process wrote `log`; the owner by default.
    ///   - capture: Sends one event (Sentry in the app, a recorder in tests).
    ///   - now: The clock of the daily hang limit.
    public init(log: URL, stateFile: URL, sends: Bool, source: RustPanicSource = .owner,
                capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.log = log
        self.stateFile = stateFile
        self.sends = sends
        self.source = source
        self.capture = capture
        self.now = now
    }

    /// The owner's log for `session` under `stateRoot` (the parent of the
    /// owner's sessions directory).
    public static func log(stateRoot: URL, session: String) -> URL {
        stateRoot.appending(path: "owner-panics-\(session).jsonl")
    }

    /// The owner's hang log for `session` under `stateRoot`, beside its panic log.
    public static func hangLog(stateRoot: URL, session: String) -> URL {
        stateRoot.appending(path: "owner-hangs-\(session).jsonl")
    }

    /// Reads now and each time the state root changes, off the main thread.
    public func start() {
        queue.async { [self] in
            forwardNew()
            watch()
        }
    }

    /// Sends the lines added since the last read. Returns the events sent.
    @discardableResult
    public func forwardNew() -> [Event] {
        let stored = loadState()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: log.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            // No log yet: the one a process creates later is new, every line of it.
            if stored == nil { save(State(offset: 0, inode: 0)) }
            return []
        }
        guard var state = stored else {
            // The first run only marks an existing log read: older lines are never sent.
            save(State(offset: size, inode: inode))
            return []
        }
        if state.inode != inode || state.offset > size { state = State(offset: 0, inode: inode) }
        guard size > state.offset, let handle = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: state.offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - state.offset)),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
        // Only whole lines; a line still being written stays for the next read.
        let complete = data[data.startIndex...lastNewline]
        var sent: [Event] = []
        var throttled = 0
        if sends {
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                guard let event = Self.event(fromLine: Data(line), source: source) else { continue }
                guard admitsHang(event, state: &state) else {
                    throttled += 1
                    continue
                }
                capture(event)
                sent.append(event)
            }
        }
        state.offset += UInt64(complete.count)
        save(state)
        if !sent.isEmpty { logger.info("forwarded \(sent.count) \(self.source.process, privacy: .public) record(s)") }
        if throttled > 0 {
            logger.info("held back \(throttled) \(self.source.process, privacy: .public) hang(s) over the daily limit")
        }
        return sent
    }

    /// Whether `event` may be sent: always for a panic; for a hang, only the first of its
    /// fingerprint today and only below ``maxHangEventsPerDay``. Records an admitted hang in `state`.
    private func admitsHang(_ event: Event, state: inout State) -> Bool {
        guard event.exceptions?.first?.type == Self.hangType, let fingerprint = event.fingerprint else {
            return true
        }
        let key = fingerprint.joined(separator: "\u{1F}")
        let day = Int64((now().timeIntervalSince1970 / 86_400).rounded(.down))
        if state.hangDay != day {
            state.hangDay = day
            state.sentHangs = []
        }
        var sentToday = state.sentHangs ?? []
        guard sentToday.count < Self.maxHangEventsPerDay, !sentToday.contains(key) else { return false }
        sentToday.append(key)
        state.sentHangs = sentToday
        return true
    }

    /// The Sentry event for one log line; nil for a test line or a line
    /// that is neither a panic nor a hang record (a lab build's slow polls).
    /// Every text the event carries is scrubbed of paths and URLs (``RustLogScrubber``).
    static func event(fromLine line: Data, source: RustPanicSource = .owner) -> Event? {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              record["test"] as? Bool != true else { return nil }
        let scrubber = RustLogScrubber()
        if record["event"] as? String == "hang" { return hangEvent(record, source: source, scrubber: scrubber) }
        guard let rawMessage = record["message"] as? String else { return nil }
        let message = scrubber.scrub(rawMessage)
        let location = scrubber.scrub(record["location"] as? String ?? "")
        let event = Event(level: .error)
        let exception = Exception(value: message, type: "RustPanic")
        let mechanism = Mechanism(type: "rust_panic")
        mechanism.handled = false
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.message = SentryMessage(formatted: "\(source.label) at \(location): \(message)")
        // Same panic site, same issue, whatever the message text holds.
        event.fingerprint = [source.fingerprintPrefix, location]
        var tags = buildTags(record, source: source)
        if let thread = record["thread"] as? String { tags["thread"] = scrubber.scrub(thread) }
        event.tags = tags
        var extra: [String: Any] = ["location": location]
        if let backtrace = record["backtrace"] as? String { extra["backtrace"] = scrubber.scrub(backtrace) }
        event.extra = extra
        return event
    }

    /// One hung scope (cmux-panic-log `hang`, written by the request watchdog): a warning grouped by
    /// scope and method, its thread's stack as `image+offset symbol` lines with no image folder.
    private static func hangEvent(_ record: [String: Any], source: RustPanicSource,
                                  scrubber: RustLogScrubber) -> Event? {
        guard let scope = record["scope"] as? String else { return nil }
        let method = scrubber.scrub(record["method"] as? String ?? scope)
        let busy = (record["busy_ms"] as? NSNumber)?.int64Value ?? 0
        let event = Event(level: .warning)
        let exception = Exception(value: "\(scope) \(method) busy \(busy) ms", type: hangType)
        let mechanism = Mechanism(type: "rust_hang")
        // The process lives on: a hang is reported, not a crash.
        mechanism.handled = true
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.message = SentryMessage(formatted: "\(source.label): \(scope) \(method) busy \(busy) ms")
        event.fingerprint = [source.fingerprintPrefix, scope, method]
        var tags = buildTags(record, source: source)
        tags["hang_scope"] = scope
        tags["hang_method"] = method
        event.tags = tags
        let frames = (record["stack"] as? [[String: Any]] ?? []).map { frame in
            let image = (frame["image"] as? String).map(scrubber.imageName) ?? "?"
            let offset = (frame["offset"] as? NSNumber)?.uint64Value ?? 0
            let symbol = (frame["symbol"] as? String).map { " " + $0 } ?? ""
            return "\(image)+0x\(String(offset, radix: 16))\(symbol)"
        }
        var extra: [String: Any] = ["stack": frames]
        for key in ["hang_ms", "busy_ms", "duration_ms", "stack_truncated"] {
            if let value = record[key] as? NSNumber { extra[key] = value }
        }
        if let error = record["stack_error"] as? String { extra["stack_error"] = error }
        event.extra = extra
        return event
    }

    /// The process, release and platform tags every record carries (cmux-tui owner_panic.rs,
    /// acpmux daemon/panic_log.rs, cmux-holder panic_log.rs), so Sentry groups by release and
    /// platform; `role` tells an acpmux agent host from its daemon.
    private static func buildTags(_ record: [String: Any], source: RustPanicSource) -> [String: String] {
        var tags = ["process": source.process, "crash_source": source.crashSource]
        for (field, tag) in [("version", "tui_version"), ("build_identity", "tui_build"), ("os", "tui_os"),
                             ("arch", "tui_arch"), ("role", "process_role")] {
            if let value = record[field] as? String { tags[tag] = value }
        }
        return tags
    }

    private func watch() {
        let directory = log.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let descriptor = unsafe open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak self] in self?.forwardNew() }
        source.setCancelHandler { close(descriptor) }
        watcher.withLock { $0 = source }
        source.resume()
    }

    private func loadState() -> State? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func save(_ state: State) {
        do {
            try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        } catch {
            logger.error("owner panic forwarder state not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
