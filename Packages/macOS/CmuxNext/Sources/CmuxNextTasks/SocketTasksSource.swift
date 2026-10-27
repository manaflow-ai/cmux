public import CmuxNextWakeups
import Darwin
import Foundation
import os

/// The local Tasks owner (`cmux task serve`) over its Unix socket, JSON
/// lines (cmux-tasks protocol.rs). Event-driven: dispatch sources wake on
/// readable data, writable space and changes in the socket's directory;
/// nothing polls. One connection carries the subscription and the intents,
/// so an intent's echo events always precede its settle.
///
/// The owner stamps the actor: a connection without a hello acts as the
/// machine's person. After a disconnect the source waits for the socket's
/// directory to change (the owner restarted), spaces attempts with
/// `Backoff`, reconnects and subscribes again; the model then resends the
/// intents it sent before the disconnect, with their keys. The backoff resets
/// only when a valid snapshot arrives, so an owner that accepts and then
/// sends a refused snapshot is retried later and later, not at once.
///
/// What the owner sends reaches the main actor as ``MainWorkClass/automation``
/// work on the app's ``MainWorkScheduler``: another process's lines, so a
/// person's pending input and the frame it shows go first (Chrome posts IPC
/// replies to the UI thread as task-runner tasks, never ahead of input:
/// content/browser/scheduler/browser_task_queues.h).
@MainActor
public final class SocketTasksSource: TasksSource {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "tasks.socket")
    private let path: String
    private var sink: (@MainActor (TasksSourceEvent) -> Void)?
    /// Whether a connection is open (its descriptor belongs to `connection`).
    private var connected = false
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    /// The directory watch's events arrive here, off main, and post to ``mainWork``.
    private let watchQueue = DispatchQueue(label: "com.cmuxterm.app.next.tasks.directory", qos: .utility)
    private let mainWork: MainWorkScheduler
    /// Interned once: the connection's queue posts each read's lines under it.
    private let linesOwner: MainTaskOwner
    private let directoryOwner: MainTaskOwner
    private let retryTimer: DemandTimer
    private var backoff: Backoff
    /// Owns the descriptor: reads, framing, JSON decoding and writes run on
    /// its queue, off the main actor (cx-9c8m).
    private var connection: TasksSocketConnection?
    /// Bumped per connection, so lines a closed connection decoded are dropped.
    private var generation = 0
    private var nextID: UInt64 = 1
    private var keysByID: [UInt64: String] = [:]

    /// - Parameters:
    ///   - path: The owner's socket; defaults to the local team's
    ///     (`~/Library/Application Support/cmux/tasks/local/tasks.sock`).
    ///   - mainWork: Where the owner's lines and the socket directory's changes run on main, as automation work.
    ///   - retryTimer: Spaces reconnect attempts; tests pass a timer on a `ManualClock`.
    ///   - backoff: The reconnect delays; tests pass one with no jitter.
    public init(path: String? = nil,
                mainWork: MainWorkScheduler,
                retryTimer: DemandTimer = DemandTimer(owner: "tasks.reconnect"),
                backoff: Backoff = Backoff(initial: .milliseconds(200), maximum: .seconds(10))) {
        self.path = path ?? Self.defaultPath(team: "local")
        self.mainWork = mainWork
        self.retryTimer = retryTimer
        self.backoff = backoff
        linesOwner = mainWork.board.owner("tasks.socket.lines")
        directoryOwner = mainWork.board.owner("tasks.socket.directory")
    }

    public static func defaultPath(team: String) -> String {
        let base = ProcessInfo.processInfo.environment["CMUX_TASKS_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/cmux/tasks")
        return base.appendingPathComponent(team).appendingPathComponent("tasks.sock").path
    }

    public func start(_ sink: @escaping @MainActor (TasksSourceEvent) -> Void) {
        self.sink = sink
        sink(.connection(.connecting))
        if !open() {
            sink(.connection(.disconnected(TasksStrings.ownerNotRunning)))
            waitForOwner()
        }
    }

    public func stop() {
        sink = nil
        retryTimer.cancel()
        directoryWatch?.cancel()
        directoryWatch = nil
        closeConnection()
    }

    public func send(_ intent: TasksIntent) {
        guard connected else { return }
        let id = nextID
        nextID += 1
        keysByID[id] = intent.key
        let wire = intent.wire
        enqueue(["id": .int(Int(id)), "op": .string(wire.op), "key": .string(intent.key), "origin": .string("user")], params: wire.params)
    }

    // MARK: - Connection

    private func open() -> Bool {
        guard let socket = Self.connect(path: path) else { return false }
        connected = true
        generation += 1
        let generation = generation
        // The main actor gets each read's decoded lines as one automation task.
        let connection = TasksSocketConnection(fd: socket)
        let mainWork = mainWork, owner = linesOwner
        connection.start { [weak self] batch in
            mainWork.postFromAnyThread(.automation, owner: owner) { [weak self] in self?.deliver(batch, generation: generation) }
        }
        self.connection = connection
        directoryWatch?.cancel()
        directoryWatch = nil
        enqueue(["id": .int(Int(nextID)), "op": .string("task.subscribe")], params: [:])
        nextID += 1
        return true
    }

    private static func connect(path: String) -> Int32? {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socket)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            // concurrency-allow: a local Unix socket connect returns at once (accepted or ECONNREFUSED); the descriptor turns O_NONBLOCK below. Moving this client off the main actor is cx-9c8m.
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, length) }
        }
        guard result == 0 else {
            close(socket)
            return nil
        }
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        return socket
    }

    private func closeConnection() {
        connection?.stop()
        connection = nil
        connected = false
        generation += 1
        keysByID.removeAll()
    }

    private func lost(reason: String = TasksStrings.ownerUnreachable) {
        closeConnection()
        guard let sink else { return }
        sink(.connection(.disconnected(reason)))
        waitForOwner()
    }

    /// Chromium's `mojo::ReportBadMessage` closes the pipe of a peer that sent
    /// a bad message; here the connection closes, the mirror keeps its last
    /// good state, and the backoff keeps growing until a valid snapshot.
    private func refuse(_ error: TasksSnapshotError) {
        switch error {
        case let .duplicateID(entity, id):
            Self.logger.error("refused a Tasks snapshot: two \(entity, privacy: .public) rows have id \(id, privacy: .private)")
        }
        lost(reason: TasksStrings.ownerSentBadSnapshot)
    }

    /// Wait for the socket's directory to change, then try again, spaced by
    /// `Backoff`. One attempt also runs after the first backoff delay, for an
    /// owner that restarts without recreating the directory entry.
    private func waitForOwner() {
        if directoryWatch == nil {
            let mainWork = mainWork, owner = directoryOwner
            directoryWatch = Self.watch(directory: (path as NSString).deletingLastPathComponent, on: watchQueue) { [weak self] in
                mainWork.postFromAnyThread(.automation, owner: owner) { [weak self] in self?.scheduleAttempt() }
            }
        }
        scheduleAttempt()
    }

    /// A running watch of `directory`'s entries whose events call `changed` on `queue`; nil when it
    /// cannot be opened. Nonisolated, so the handler is not inferred to the main actor it never runs on.
    private nonisolated static func watch(directory: String, on queue: DispatchQueue,
                                          changed: @escaping @Sendable () -> Void) -> (any DispatchSourceFileSystemObject)? {
        let dirFD = Darwin.open(directory, O_EVTONLY)
        guard dirFD >= 0 else { return nil }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: queue)
        watch.setEventHandler { changed() }
        watch.setCancelHandler { close(dirFD) }
        watch.resume()
        return watch
    }

    /// One attempt after the next `Backoff` delay (a one-shot timer, never a poll).
    private func scheduleAttempt() {
        guard !retryTimer.isScheduled, sink != nil, !connected else { return }
        retryTimer.scheduleOnMain(after: backoff.next()) { [weak self] in
            self?.attempt()
        }
    }

    private func attempt() {
        guard !connected, let sink else { return }
        sink(.connection(.connecting))
        if !open() {
            sink(.connection(.disconnected(TasksStrings.ownerNotRunning)))
        }
    }

    // MARK: - Reading

    private func deliver(_ batch: TasksSocketConnection.Batch, generation: Int) {
        guard generation == self.generation, connected else { return }
        for line in batch.lines {
            dispatch(line)
            if !connected { return }
        }
        if batch.ended { lost() }
    }

    private func dispatch(_ line: TasksWire.Line) {
        switch line {
        case let .snapshot(snapshot):
            backoff.reset()
            sink?(.snapshot(snapshot))
        case let .event(event):
            sink?(.event(event))
        case let .reply(id, reject):
            if let key = keysByID.removeValue(forKey: id) {
                sink?(.settled(key: key, reject: reject))
            }
        case let .badSnapshot(error):
            refuse(error)
        case .ignored:
            break
        }
    }

    // MARK: - Writing

    private func enqueue(_ fields: [String: TasksJSON], params: [String: TasksJSON]) {
        guard connected, let connection, var data = try? JSONEncoder().encode(TasksRequestLine(fields: fields, params: params)) else { return }
        data.append(UInt8(ascii: "\n"))
        connection.send(data)
    }
}

/// One Tasks connection's descriptor, confined to its own serial queue:
/// non-blocking reads, newline framing, JSON decoding and writes never run on
/// the main actor. A snapshot line can be large; the scan resumes where the
/// last read stopped (no rescan of a partial line), and a line over
/// `inboxLimit` ends the connection (the source reconnects and resyncs).
/// The descriptor is closed only after every dispatch source on it finished
/// cancelling, so its number is never reused under a read or a write.
// crash-allow: every mutable field is touched only on `queue` (a serial queue); the public methods hop onto it.
nonisolated final class TasksSocketConnection: @unchecked Sendable {
    struct Batch: Sendable {
        var lines: [TasksWire.Line] = []
        /// EOF, a read or write error, or an oversized line: the connection is over.
        var ended = false
    }

    static let inboxLimit = 64 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.cmuxterm.app.next.tasks.socket", qos: .userInitiated)
    private let fd: Int32
    // Everything below is touched only on `queue`.
    private var deliver: (@Sendable (Batch) -> Void)?
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var inbox = Data()
    private var scanned = 0
    private var outbox = Data()
    private var stopped = false
    /// Sources whose cancel handler has not run yet; the descriptor closes at zero.
    private var openSources = 0

    init(fd: Int32) {
        self.fd = fd
    }

    /// Starts reading; `deliver` gets each read's decoded lines, in order, on the queue.
    func start(deliver: @escaping @Sendable (Batch) -> Void) {
        queue.async { [self] in
            self.deliver = deliver
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            // Strong: the descriptor must close even after the owner let go.
            source.setCancelHandler { self.sourceCancelled() }
            openSources += 1
            readSource = source
            source.resume()
        }
    }

    /// Queues `data` for writing.
    func send(_ data: Data) {
        queue.async { [self] in
            guard !stopped else { return }
            outbox.append(data)
            flush()
        }
    }

    /// Ends the connection: cancels both sources; the last cancel handler closes the descriptor.
    func stop() {
        queue.async { [self] in finish() }
    }

    private func finish() {
        guard !stopped else { return }
        stopped = true
        deliver = nil
        outbox.removeAll()
        if readSource == nil, writeSource == nil {
            close(fd)
            return
        }
        readSource?.cancel()
        writeSource?.cancel()
        readSource = nil
        writeSource = nil
    }

    private func sourceCancelled() {
        openSources -= 1
        if openSources == 0 { close(fd) }
    }

    private func end() {
        var batch = Batch()
        batch.ended = true
        deliver?(batch)
        finish()
    }

    private func readAvailable() {
        guard !stopped else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        // concurrency-allow: O_NONBLOCK descriptor read on the connection's queue, from its readable dispatch source.
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n > 0 else { return end() }
        inbox.append(contentsOf: chunk[0..<n])
        // One pass over the new bytes, one removal at the end.
        var batch = Batch()
        var start = inbox.startIndex
        var from = inbox.index(inbox.startIndex, offsetBy: scanned)
        while let newline = inbox[from...].firstIndex(of: UInt8(ascii: "\n")) {
            batch.lines.append(TasksWire.decode(Data(inbox[start..<newline])))
            start = inbox.index(after: newline)
            from = start
        }
        inbox.removeSubrange(inbox.startIndex..<start)
        scanned = inbox.count
        if !batch.lines.isEmpty { deliver?(batch) }
        if inbox.count > Self.inboxLimit { end() }
    }

    /// Writes what the socket takes now; waits for writable space for the rest.
    private func flush() {
        guard !stopped else { return }
        while !outbox.isEmpty {
            // concurrency-allow: O_NONBLOCK descriptor on the connection's queue; a full socket returns EAGAIN and the write source resumes it.
            let n = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outbox.removeSubrange(outbox.startIndex..<outbox.startIndex + n)
            } else if n < 0, errno == EAGAIN {
                break
            } else if n < 0, errno == EINTR {
                continue
            } else {
                return end()
            }
        }
        if outbox.isEmpty {
            // A writable socket fires constantly: drop the source until bytes wait again.
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.flush() }
            source.setCancelHandler { self.sourceCancelled() }
            openSources += 1
            writeSource = source
            source.resume()
        }
    }
}

/// `{"id", "op", "key"?, "origin"?, "params"}` with arbitrary top-level fields.
private nonisolated struct TasksRequestLine: Encodable {
    var fields: [String: TasksJSON]
    var params: [String: TasksJSON]

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (key, value) in fields { try container.encode(value, forKey: Key(stringValue: key)) }
        try container.encode(params, forKey: Key(stringValue: "params"))
    }
}
