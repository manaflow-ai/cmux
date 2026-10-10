public import Foundation
public import Sentry
import CmuxNextCompat
import os

/// Sends the cmux-tui owner's panic log to Sentry (cx-urd.59).
///
/// The owner appends one JSON line per panic to
/// `owner-panics-<session>.jsonl` at its state root (message, location,
/// thread, backtrace). This reads the lines added since the last read (a
/// byte offset kept in `stateFile`) and sends each as an event: a panic does
/// not always end the owner (worker threads, caught panics), so it is not a
/// crash report. The first run marks the existing log read. Lines from a
/// time reports were off (`sends` false) are
/// marked read and never sent. Debug test panics (`"test": true`) are
/// skipped.
public final class OwnerPanicForwarder: Sendable {
    struct State: Codable, Equatable {
        /// Bytes of the log already read.
        var offset: UInt64
        /// The log's file identity, so a recreated log is read from the start.
        var inode: UInt64
    }

    private let log: URL
    private let stateFile: URL
    private let sends: Bool
    private let capture: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.owner-panic-forwarder", qos: .utility)
    private let watcher = Mutex<(any DispatchSourceFileSystemObject)?>(nil)
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "crash")

    public init(log: URL, stateFile: URL, sends: Bool,
                capture: @escaping @Sendable (Event) -> Void = { SentrySDK.capture(event: $0, scope: Scope()) }) {
        self.log = log
        self.stateFile = stateFile
        self.sends = sends
        self.capture = capture
    }

    /// The owner's log for `session` under `stateRoot` (the parent of the
    /// owner's sessions directory).
    public static func log(stateRoot: URL, session: String) -> URL {
        stateRoot.appending(path: "owner-panics-\(session).jsonl")
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
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: log.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { return [] }
        guard var state = loadState() else {
            // The first run only marks the log read: older lines are never sent.
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
        if sends {
            for line in complete.split(separator: UInt8(ascii: "\n")) {
                guard let event = Self.event(fromLine: Data(line)) else { continue }
                capture(event)
                sent.append(event)
            }
        }
        state.offset += UInt64(complete.count)
        save(state)
        if !sent.isEmpty { logger.info("forwarded \(sent.count) owner panic(s)") }
        return sent
    }

    /// The Sentry event for one log line; nil for a test line or a line
    /// that is not a panic record.
    static func event(fromLine line: Data) -> Event? {
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
        event.message = SentryMessage(formatted: "cmux-tui owner panic at \(location): \(message)")
        // Same panic site, same issue, whatever the message text holds.
        event.fingerprint = ["owner-panic", location]
        var tags = ["process": "cmux-tui", "crash_source": "owner_panic_log"]
        if let thread = record["thread"] as? String { tags["thread"] = thread }
        if let version = record["version"] as? String { tags["tui_version"] = version }
        event.tags = tags
        var extra: [String: Any] = ["location": location]
        if let backtrace = record["backtrace"] as? String { extra["backtrace"] = backtrace }
        event.extra = extra
        return event
    }

    private func watch() {
        let directory = log.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
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
