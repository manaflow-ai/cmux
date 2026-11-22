import CmuxNextWakeups
import Darwin
import Foundation

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
/// intents it sent before the disconnect, with their keys.
@MainActor
public final class SocketTasksSource: TasksSource {
    private let path: String
    private var sink: (@MainActor (TasksSourceEvent) -> Void)?
    private var fd: Int32 = -1
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var directoryWatch: (any DispatchSourceFileSystemObject)?
    private let retryTimer = DemandTimer(owner: "tasks.reconnect")
    private var backoff = Backoff(initial: .milliseconds(200), maximum: .seconds(10))
    private var inbox = Data()
    private var outbox = Data()
    private var nextID: UInt64 = 1
    private var keysByID: [UInt64: String] = [:]

    /// `path` defaults to the local team's socket
    /// (`~/Library/Application Support/cmux/tasks/local/tasks.sock`).
    public init(path: String? = nil) {
        self.path = path ?? Self.defaultPath(team: "local")
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
        guard fd >= 0 else { return }
        let id = nextID
        nextID += 1
        keysByID[id] = intent.key
        let wire = intent.wire
        enqueue(["id": .int(Int(id)), "op": .string(wire.op), "key": .string(intent.key), "origin": .string("user")], params: wire.params)
    }

    // MARK: - Connection

    private func open() -> Bool {
        guard let socket = Self.connect(path: path) else { return false }
        fd = socket
        let read = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        read.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.readAvailable() } } // main-proof: dispatch source on queue: .main
        read.resume()
        readSource = read
        backoff.reset()
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
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        inbox.removeAll()
        outbox.removeAll()
        keysByID.removeAll()
    }

    private func lost() {
        closeConnection()
        guard let sink else { return }
        sink(.connection(.disconnected(TasksStrings.ownerUnreachable)))
        waitForOwner()
    }

    /// Wait for the socket's directory to change, then try again, spaced by
    /// `Backoff`. One attempt also runs after the first backoff delay, for an
    /// owner that restarts without recreating the directory entry.
    private func waitForOwner() {
        if directoryWatch == nil {
            let directory = (path as NSString).deletingLastPathComponent
            let dirFD = Darwin.open(directory, O_EVTONLY)
            if dirFD >= 0 {
                let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFD, eventMask: [.write, .rename, .delete], queue: .main)
                watch.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleAttempt() } } // main-proof: dispatch source on queue: .main
                watch.setCancelHandler { close(dirFD) }
                watch.resume()
                directoryWatch = watch
            }
        }
        scheduleAttempt()
    }

    /// One attempt after the next `Backoff` delay (a one-shot timer, never a poll).
    private func scheduleAttempt() {
        guard !retryTimer.isScheduled, sink != nil, fd < 0 else { return }
        retryTimer.schedule(after: backoff.next()) { @MainActor [weak self] in
            self?.attempt()
        }
    }

    private func attempt() {
        guard fd < 0, let sink else { return }
        sink(.connection(.connecting))
        if !open() {
            sink(.connection(.disconnected(TasksStrings.ownerNotRunning)))
        }
    }

    // MARK: - Reading

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n < 0, errno == EAGAIN || errno == EINTR { return }
        guard n > 0 else {
            lost()
            return
        }
        inbox.append(contentsOf: chunk[0..<n])
        // One pass over the buffer, one removal at the end (no quadratic splits).
        var start = inbox.startIndex
        while let newline = inbox[start...].firstIndex(of: UInt8(ascii: "\n")) {
            dispatch(TasksWire.decode(Data(inbox[start..<newline])))
            start = inbox.index(after: newline)
            if fd < 0 { return }
        }
        inbox.removeSubrange(inbox.startIndex..<start)
    }

    private func dispatch(_ line: TasksWire.Line) {
        switch line {
        case let .snapshot(snapshot):
            sink?(.snapshot(snapshot))
        case let .event(event):
            sink?(.event(event))
        case let .reply(id, reject):
            if let key = keysByID.removeValue(forKey: id) {
                sink?(.settled(key: key, reject: reject))
            }
        case .ignored:
            break
        }
    }

    // MARK: - Writing

    private func enqueue(_ fields: [String: TasksJSON], params: [String: TasksJSON]) {
        guard fd >= 0, var data = try? JSONEncoder().encode(TasksRequestLine(fields: fields, params: params)) else { return }
        data.append(UInt8(ascii: "\n"))
        outbox.append(data)
        flush()
    }

    /// Write what the socket takes now; wait for writable space for the rest.
    private func flush() {
        while !outbox.isEmpty {
            let n = outbox.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outbox.removeSubrange(outbox.startIndex..<outbox.startIndex + n)
            } else if n < 0, errno == EAGAIN {
                break
            } else if n < 0, errno == EINTR {
                continue
            } else {
                lost()
                return
            }
        }
        if outbox.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.flush() } } // main-proof: dispatch source on queue: .main
            source.resume()
            writeSource = source
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
