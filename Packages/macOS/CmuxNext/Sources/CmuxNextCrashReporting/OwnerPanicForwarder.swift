public import Foundation
public import Sentry
import CmuxNextCompat
import CmuxNextWakeups
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
///
/// ``start()`` reads at once and again on each change, with one kqueue watch per log folder, per log file (an append
/// to a file that exists changes no folder) and, for a log folder that does not exist yet, per nearest folder above it
/// that does, until it appears.
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
    /// The most hang lines kept for a hang-report sink that is not attached yet (``setHangEntries(_:)``).
    public static let maxPendingHangEntries = 64

    /// One hang line read before the hang-report sink was attached.
    private struct PendingHang: Sendable {
        let record: RustHangRecord
        let source: RustPanicSource
    }

    /// Where hang lines go besides Sentry.
    private enum HangSink: Sendable {
        /// No sink yet: the lines read so far, oldest first.
        case pending([PendingHang])
        case attached(HangEntries)
    }

    /// What one watch is for.
    private enum WatchKind: Sendable, Equatable {
        /// A log folder, or the folder of per-process log folders: an entry was added, removed or renamed.
        case folder
        /// A log file of this inode: it grew.
        case file(inode: UInt64)
        /// The nearest existing folder above these log folders, which do not exist yet.
        case parent(waitingFor: [URL])

        /// Whether a watch of `self` serves as one of `other` (a parent's folder list may change in place).
        func sameWatch(as other: WatchKind) -> Bool {
            switch (self, other) {
            case (.folder, .folder), (.parent, .parent): true
            case (.file(let inode), .file(let other)): inode == other
            default: false
            }
        }
    }

    private struct Watch {
        var kind: WatchKind
        let source: any DispatchSourceFileSystemObject
    }

    private let logs: [RustDiagnosticsLog]
    private let stateFile: URL
    private let legacyStates: [String: URL]
    private let sends: Bool
    private let capture: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.owner-panic-forwarder", qos: .utility)
    // Lock carve-out: only `queue` reads or changes the watches (and deinit, after the last use); the Mutex is the
    // Sendable storage of that queue-confined table and is never contended, so opening a watch's descriptor under it
    // makes no thread wait.
    private let watches = Mutex<[String: Watch]>([:])
    // Lock carve-out: attached once at launch and read once per hang line, both on `queue`; the Mutex is the Sendable
    // storage of that queue-confined value and is never contended.
    private let hangSink: Mutex<HangSink>
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
    /// The watches' record in the launch's arm census (Debug and bench builds, p08-startup-085): the first watch
    /// armed and the first event of any of them.
    private let census: ArmCensusWatch

    /// - Parameters:
    ///   - logs: The logs to read (``RustDiagnosticsLog/all(_:)`` in the app).
    ///   - stateFile: Where the read offsets are kept.
    ///   - legacyStates: The state file an earlier build kept per log file (`{offset, inode}`), by the log's path:
    ///     at the first run each one's offset is kept, so no line is lost or sent twice when this build first runs.
    ///   - sends: The user's telemetry choice; false marks lines read without sending.
    ///   - hangEntries: Where each hang line sent goes besides Sentry; nil until ``setHangEntries(_:)`` attaches it, and
    ///     the lines read before that are handed on then.
    ///   - file: The line that made it, named by the arm census (leave the default).
    ///   - line: See `file`.
    ///   - capture: Sends one event (Sentry in the app, a recorder in tests).
    public init(logs: [RustDiagnosticsLog], stateFile: URL, legacyStates: [URL: URL] = [:], sends: Bool,
                hangEntries: HangEntries? = nil, file: StaticString = #fileID, line: UInt = #line,
                capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.logs = logs
        self.stateFile = stateFile
        self.legacyStates = Dictionary(legacyStates.map { ($0.key.path, $0.value) }, uniquingKeysWith: { first, _ in first })
        self.sends = sends
        self.capture = capture
        hangSink = Mutex(hangEntries.map(HangSink.attached) ?? .pending([]))
        census = ArmCensusWatch(.watcher, owner: "OwnerPanicForwarder", file: file, line: line)
    }

    deinit {
        watches.withLock { table in
            for watch in table.values { watch.source.cancel() }
        }
    }

    /// One panic log.
    /// - Parameters:
    ///   - log: The panic log to read.
    ///   - stateFile: Where the read offset is kept (one per log).
    ///   - sends: The user's telemetry choice; false marks lines read without sending.
    ///   - source: Which process wrote `log`; the owner by default.
    ///   - file: The line that made it, named by the arm census (leave the default).
    ///   - line: See `file`.
    ///   - capture: Sends one event (Sentry in the app, a recorder in tests).
    public convenience init(log: URL, stateFile: URL, sends: Bool, source: RustPanicSource = .owner,
                            file: StaticString = #fileID, line: UInt = #line,
                            capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.init(logs: [.file(log, source: source, kind: .panic)], stateFile: stateFile, sends: sends, file: file,
                  line: line, capture: capture)
    }

    /// The owner's log for `session` under `stateRoot` (the parent of the
    /// owner's sessions directory).
    public static func log(stateRoot: URL, session: String) -> URL {
        stateRoot.appending(path: "owner-panics-\(session).jsonl")
    }

    /// Attaches where each hang line sent goes besides Sentry (the hang-report collector, which exists after crash
    /// reporting starts), once at launch, off the caller's thread: the lines read before it (at most
    /// ``maxPendingHangEntries``, the backlog read at start among them) are handed on first.
    public func setHangEntries(_ entries: @escaping HangEntries) {
        queue.async { [self] in
            let pending = hangSink.withLock { sink -> [PendingHang] in
                defer { sink = .attached(entries) }
                guard case .pending(let pending) = sink else { return [] }
                return pending
            }
            for hang in pending { entries(hang.record, hang.source) }
        }
    }

    /// Reads now and on each change of a log's folder or file, off the main thread.
    public func start() {
        queue.async { [self] in firstPass() }
    }

    /// ``start()``'s work on the calling thread, which may block on files (a launch lane post,
    /// ``CrashForwarders/run()``): makes the log folders the app may make, watches each log's folder and file,
    /// then reads the lines added since the last read. It runs as one item of the forwarder's queue, so a watch
    /// event that fires during the read waits for it and a line is never sent twice. Call it, or ``start()``, once.
    public func forwardAndWatch() {
        queue.sync { firstPass() }
    }

    /// The first pass (on `queue`).
    private func firstPass() {
        for log in logs where log.createsDirectory {
            try? FileManager.checked.createDirectory(at: log.directory, withIntermediateDirectories: true)
        }
        // Watch first: a line added between the read and the watch would wait for the next change.
        updateWatches()
        forwardNew()
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
        guard size > offset, let handle = try? FileHandle.blockingForReading(from: file) else { return 0 }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.blockingRead(upToCount: Int(size - offset)),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        // Only whole lines; a line still being written stays for the next read.
        let complete = data[data.startIndex...lastNewline]
        guard sends else { return UInt64(complete.count) }
        var sources: [UInt32: RustPanicSource] = [:]
        var count = 0
        for line in complete.split(separator: UInt8(ascii: "\n")) where count < Self.maxEventsPerFile {
            switch log.kind {
            case .panic:
                guard let event = Self.event(fromLine: Data(line), source: log.source) else { continue }
                capture(event)
                sent.append(event)
            case .hang:
                guard let record = RustHangRecord(line: Data(line)) else { continue }
                let source = sources[record.pid] ?? log.process(ofPID: record.pid, in: file)
                sources[record.pid] = source
                let event = record.event(source: source)
                capture(event)
                sent.append(event)
                handOn(record, source)
            }
            count += 1
        }
        return UInt64(complete.count)
    }

    /// Hands one hang line sent to the hang-report sink, or keeps it until the sink attaches.
    private func handOn(_ record: RustHangRecord, _ source: RustPanicSource) {
        let entries = hangSink.withLock { sink -> HangEntries? in
            switch sink {
            case .attached(let entries):
                return entries
            case .pending(var pending):
                if pending.count < Self.maxPendingHangEntries { pending.append(PendingHang(record: record, source: source)) }
                sink = .pending(pending)
                return nil
            }
        }
        entries?(record, source)
    }

    /// The file's size and inode; nil when it cannot be read.
    private static func identity(of file: URL) -> (size: UInt64, inode: UInt64)? {
        guard let attributes = try? FileManager.checked.attributesOfItem(atPath: file.path),
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
        let source = source.labeling(lineSource: record["source"] as? String)
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

    /// Makes the watches match the logs on disk now (on `queue`): each existing log folder (and each per-process
    /// folder), each log file (at most ``maxFileWatches``), and for a log folder that does not exist the nearest
    /// existing folder above it. A pass that changed a watch is followed by another, so a folder or file that appeared
    /// between a pass's listing and its watch is watched too. Returns whether a folder or file watch was added.
    @discardableResult
    private func updateWatches() -> Bool {
        var added = false
        for _ in 0..<Self.maxWatchPasses {
            let pass = watchPass()
            added = added || pass.added
            guard pass.changed else { break }
        }
        return added
    }

    /// The most passes of one ``updateWatches()``: one per folder level a log folder can gain while it runs.
    private static let maxWatchPasses = 8
    /// The most log files watched one by one (one descriptor each); a file past it is read on its folder's events.
    static let maxFileWatches = 256

    /// One pass of ``updateWatches()``: whether it added or removed a watch, and whether it added a folder or file one.
    private func watchPass() -> (changed: Bool, added: Bool) {
        var wanted: [String: (url: URL, kind: WatchKind)] = [:]
        var fileWatches = 0
        func want(_ url: URL, _ kind: WatchKind) {
            let key = url.path
            switch (wanted[key]?.kind, kind) {
            case (.folder?, _):
                return
            case (.parent(let waiting)?, .parent(let more)):
                wanted[key] = (url, .parent(waitingFor: waiting + more))
            case (_, .file):
                guard fileWatches < Self.maxFileWatches else { return }
                fileWatches += 1
                wanted[key] = (url, kind)
            default:
                wanted[key] = (url, kind)
            }
        }
        for log in logs {
            guard RustDiagnosticsLog.isDirectory(log.directory) else {
                want(Self.nearestExistingFolder(log.directory), .parent(waitingFor: [log.directory]))
                continue
            }
            want(log.directory, .folder)
            if log.perProcessFolders != nil {
                for folder in log.folders() { want(folder, .folder) }
            }
            for file in log.files() {
                if let identity = Self.identity(of: file) { want(file, .file(inode: identity.inode)) }
            }
        }
        return watches.withLock { table in
            var changed = false
            var added = false
            for (key, watch) in table where !(wanted[key].map { watch.kind.sameWatch(as: $0.kind) } ?? false) {
                watch.source.cancel()
                table[key] = nil
                changed = true
            }
            for (key, target) in wanted {
                if table[key] != nil {
                    table[key]?.kind = target.kind
                    continue
                }
                guard let source = watchSource(target.url, kind: target.kind, key: key) else { continue }
                table[key] = Watch(kind: target.kind, source: source)
                changed = true
                if case .parent = target.kind { continue }
                added = true
            }
            return (changed, added)
        }
    }

    /// One watch's event (on `queue`).
    private func changed(_ key: String) {
        switch watches.withLock({ $0[key]?.kind }) {
        case nil:
            return
        case .parent(let waiting)?:
            // Most entries added there are other files: only a log folder, or a folder on the way to one, counts.
            guard waiting.contains(where: { Self.nearestExistingFolder($0).path != key }) else { return }
            if updateWatches() { forwardNew() }
        case .folder?, .file?:
            updateWatches()
            forwardNew()
        }
    }

    private func watchSource(_ url: URL, kind: WatchKind, key: String) -> (any DispatchSourceFileSystemObject)? {
        // SAFETY: open reads the NUL-terminated copy of the path made for the call.
        let descriptor = unsafe blockingOpen(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let mask: DispatchSource.FileSystemEvent = switch kind {
        case .file: [.extend, .write, .delete, .rename]
        case .folder, .parent: [.write, .rename, .delete]
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: mask, queue: queue)
        source.setEventHandler { [weak self] in
            self?.census.fired()
            self?.changed(key)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        census.armed()
        return source
    }

    /// `folder` when it exists, else the nearest folder above it that does (`/` at last).
    private static func nearestExistingFolder(_ folder: URL) -> URL {
        var candidate = folder
        while !RustDiagnosticsLog.isDirectory(candidate), candidate.pathComponents.count > 1 {
            candidate = candidate.deletingLastPathComponent()
        }
        return candidate
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
