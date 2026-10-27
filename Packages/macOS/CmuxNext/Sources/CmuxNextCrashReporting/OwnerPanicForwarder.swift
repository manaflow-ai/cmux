public import Foundation
public import Sentry
import CmuxNextCompat
import os

/// The forwarder of every cmux Rust process's diagnostics logs (p09-observability-075).
public typealias RustDiagnosticsForwarder = OwnerPanicForwarder

/// Sends cmux Rust processes' panic and hang logs to Sentry (cx-urd.59, p09-observability-075).
///
/// Each ``RustDiagnosticsLog`` is a family of JSONL files: a panic log (`cmux-panic-log`: message, location,
/// thread, backtrace) or a hang log (`cmux-hang-watch`'s `hangs-<pid>.jsonl`, ``RustHangRecord``). This reads
/// the lines added to each file since the last read (a byte offset per file, kept in `stateFile`) and sends each
/// as an event: a panic does not always end its process (worker threads, caught panics), so it is not a crash
/// report, and a hang is Chrome's `HangWatcher::RecordHang` dump (base/threading/hang_watcher.cc). A hang line is
/// also handed to the hang-report sink (``setHangEntries(_:)``).
///
/// The first run marks every existing line read; a file that appears after it is read from its start. Lines from
/// a time reports were off (`sends` false) are marked read and never sent nor handed on. Debug test panics
/// (`"test": true`) are skipped. At most ``maxEventsPerFile`` lines of one file are sent per read, so a hang or
/// panic loop cannot flood the project; the rest are marked read.
public final class OwnerPanicForwarder: Sendable {
    struct State: Codable, Equatable {
        /// One file's read position.
        struct File: Codable, Equatable {
            /// Bytes of the file already read.
            var offset: UInt64
            /// The file's identity, so a recreated file is read from the start.
            var inode: UInt64
        }

        /// Each file read so far, by path.
        var files: [String: File]
    }

    /// Receives each hang line sent (the hang-report collector in the app).
    public typealias HangEntries = @Sendable (RustHangRecord, RustPanicSource) -> Void

    /// The most lines of one file sent per read.
    public static let maxEventsPerFile = 20

    private let logs: [RustDiagnosticsLog]
    private let stateFile: URL
    private let legacyStates: [String: URL]
    private let sends: Bool
    private let capture: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.owner-panic-forwarder", qos: .utility)
    private let watchers = Mutex<[any DispatchSourceFileSystemObject]>([])
    // Lock carve-out: set once at launch (the collector exists after crash reporting starts) and read once per
    // hang line on `queue`; an actor would add a hop per line to a queue that already serializes the reads.
    private let hangEntries = Mutex<HangEntries?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    /// - Parameters:
    ///   - logs: The logs to read (``RustDiagnosticsLog/all(_:)`` in the app).
    ///   - stateFile: Where the read offsets are kept.
    ///   - legacyStates: The state file an earlier build kept per log file (`{offset, inode}`), by the log's path:
    ///     at the first run each one's offset is kept, so no line is lost or sent twice when this build first runs.
    ///   - sends: The user's telemetry choice; false marks lines read without sending.
    ///   - capture: Sends one event (Sentry in the app, a recorder in tests).
    public init(logs: [RustDiagnosticsLog], stateFile: URL, legacyStates: [URL: URL] = [:], sends: Bool,
                capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.logs = logs
        self.stateFile = stateFile
        self.legacyStates = Dictionary(legacyStates.map { ($0.key.path, $0.value) }, uniquingKeysWith: { first, _ in first })
        self.sends = sends
        self.capture = capture
    }

    /// One panic log.
    /// - Parameters:
    ///   - log: The panic log to read.
    ///   - stateFile: Where the read offset is kept (one per log).
    ///   - sends: The user's telemetry choice; false marks lines read without sending.
    ///   - source: Which process wrote `log`; the owner by default.
    ///   - capture: Sends one event (Sentry in the app, a recorder in tests).
    public convenience init(log: URL, stateFile: URL, sends: Bool, source: RustPanicSource = .owner,
                            capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.init(logs: [.file(log, source: source, kind: .panic)], stateFile: stateFile, sends: sends, capture: capture)
    }

    /// The owner's log for `session` under `stateRoot` (the parent of the
    /// owner's sessions directory).
    public static func log(stateRoot: URL, session: String) -> URL {
        stateRoot.appending(path: "owner-panics-\(session).jsonl")
    }

    /// Where each hang line sent goes besides Sentry (the hang-report collector); set once at launch.
    public func setHangEntries(_ entries: @escaping HangEntries) {
        hangEntries.withLock { $0 = entries }
    }

    /// Reads now and each time a log's folder changes, off the main thread.
    public func start() {
        queue.async { [self] in
            forwardNew()
            watch()
        }
    }

    /// Sends the lines added since the last read. Returns the events sent.
    @discardableResult
    public func forwardNew() -> [Event] {
        let loaded = loadState()
        var state = loaded ?? State(files: [:])
        var seen: Set<String> = []
        var sent: [Event] = []
        for log in logs {
            for file in log.files() {
                guard let identity = Self.identity(of: file) else { continue }
                let key = file.path
                seen.insert(key)
                guard loaded != nil else {
                    // The first run only marks the logs read: older lines are never sent.
                    state.files[key] = legacyEntry(for: file, identity: identity)
                        ?? State.File(offset: identity.size, inode: identity.inode)
                    continue
                }
                var entry = state.files[key] ?? State.File(offset: 0, inode: identity.inode)
                if entry.inode != identity.inode || entry.offset > identity.size { entry = State.File(offset: 0, inode: identity.inode) }
                entry.offset += readLines(file, from: entry.offset, size: identity.size, log: log, into: &sent)
                state.files[key] = entry
            }
        }
        // A file that is gone (a dead process's log the cleanup removed) is forgotten.
        state.files = state.files.filter { seen.contains($0.key) }
        if state != loaded { save(state) }
        if !sent.isEmpty { logger.info("forwarded \(sent.count) Rust diagnostics event(s)") }
        return sent
    }

    /// Reads the whole lines of `file` past `offset` and sends them; returns the bytes read.
    private func readLines(_ file: URL, from offset: UInt64, size: UInt64, log: RustDiagnosticsLog, into sent: inout [Event]) -> UInt64 {
        guard size > offset, let handle = try? FileHandle(forReadingFrom: file) else { return 0 }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(size - offset)),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        // Only whole lines; a line still being written stays for the next read.
        let complete = data[data.startIndex...lastNewline]
        guard sends else { return UInt64(complete.count) }
        let entries: HangEntries? = log.kind == .hang ? hangEntries.withLock({ $0 }) : nil
        var count = 0
        for line in complete.split(separator: UInt8(ascii: "\n")) where count < Self.maxEventsPerFile {
            switch log.kind {
            case .panic:
                guard let event = Self.event(fromLine: Data(line), source: log.source) else { continue }
                capture(event)
                sent.append(event)
            case .hang:
                guard let record = RustHangRecord(line: Data(line)) else { continue }
                let event = record.event(source: log.source)
                capture(event)
                sent.append(event)
                entries?(record, log.source)
            }
            count += 1
        }
        return UInt64(complete.count)
    }

    /// The file's size and inode; nil when it cannot be read.
    private static func identity(of file: URL) -> (size: UInt64, inode: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        return (size, inode)
    }

    /// The earlier build's offset for `file`, when it kept one for this log and the file is still that one.
    private func legacyEntry(for file: URL, identity: (size: UInt64, inode: UInt64)) -> State.File? {
        guard let legacyState = legacyStates[file.path],
              let data = try? Data(contentsOf: legacyState),
              let legacy = try? JSONDecoder().decode(State.File.self, from: data),
              legacy.inode == identity.inode, legacy.offset <= identity.size else { return nil }
        return legacy
    }

    /// The Sentry event for one log line; nil for a test line or a line
    /// that is not a panic record.
    static func event(fromLine line: Data, source: RustPanicSource = .owner) -> Event? {
        guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = record["message"] as? String,
              record["test"] as? Bool != true else { return nil }
        let location = record["location"] as? String ?? ""
        let event = Event(level: .error)
        let exception = Exception(value: message, type: "RustPanic")
        let mechanism = Mechanism(type: "rust_panic")
        mechanism.handled = false
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.message = SentryMessage(formatted: "\(source.label) at \(location): \(message)")
        // Same panic site, same issue, whatever the message text holds.
        event.fingerprint = [source.fingerprintPrefix, location]
        var tags = ["process": source.process, "crash_source": source.crashSource]
        if let thread = record["thread"] as? String { tags["thread"] = thread }
        if let version = record["version"] as? String { tags["tui_version"] = version }
        // The build and platform a tester runs (cmux-tui owner_panic.rs), so
        // Sentry groups crashes by release and platform.
        if let build = record["build_identity"] as? String { tags["tui_build"] = build }
        if let os = record["os"] as? String { tags["tui_os"] = os }
        if let arch = record["arch"] as? String { tags["tui_arch"] = arch }
        event.tags = tags
        var extra: [String: Any] = ["location": location]
        if let backtrace = record["backtrace"] as? String { extra["backtrace"] = backtrace }
        event.extra = extra
        return event
    }

    /// One watch per folder of the logs (several logs share the state root).
    private func watch() {
        var directories: [URL] = []
        for log in logs where !directories.contains(log.directory) {
            if log.createsDirectory {
                try? FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
            }
            directories.append(log.directory)
        }
        let sources = directories.compactMap(watchSource)
        watchers.withLock { $0 = sources }
    }

    private func watchSource(_ directory: URL) -> (any DispatchSourceFileSystemObject)? {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let descriptor = unsafe open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename],
                                                               queue: queue)
        source.setEventHandler { [weak self] in self?.forwardNew() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
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
            logger.error("Rust diagnostics forwarder state not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
