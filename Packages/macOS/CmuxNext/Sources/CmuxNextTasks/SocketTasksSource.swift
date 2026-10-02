import Darwin
import Foundation

/// The local Tasks owner (`cmux task serve`) over its Unix socket, JSON
/// lines (cmux-tasks protocol.rs). Event-driven: a dispatch read source
/// wakes on data; nothing polls. One connection carries the subscription
/// and the intents, so an intent's echo events always precede its settle.
@MainActor
public final class SocketTasksSource: TasksSource {
    private let path: String
    private var sink: (@MainActor (TasksSourceEvent) -> Void)?
    private var fd: Int32 = -1
    private var readSource: (any DispatchSourceRead)?
    private var buffer = Data()
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
        guard connect() else {
            sink(.connection(.disconnected(TasksStrings.ownerNotRunning)))
            return
        }
        write(["id": .int(Int(nextID)), "op": .string("task.subscribe")], params: [:])
        nextID += 1
    }

    public func stop() {
        readSource?.cancel()
        readSource = nil
        sink = nil
    }

    public func send(_ intent: TasksIntent) {
        let id = nextID
        nextID += 1
        keysByID[id] = intent.key
        let wire = intent.wire
        write(["id": .int(Int(id)), "op": .string(wire.op), "key": .string(intent.key), "origin": .string("user")], params: wire.params)
    }

    private func connect() -> Bool {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(socket)
            return false
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
            return false
        }
        var noSigPipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fd = socket
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAvailable() }
        }
        source.setCancelHandler { close(socket) }
        source.resume()
        readSource = source
        return true
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else {
            readSource?.cancel()
            readSource = nil
            sink?(.connection(.disconnected(TasksStrings.ownerUnreachable)))
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            dispatch(TasksWire.decode(Data(line)))
        }
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

    private func write(_ fields: [String: TasksJSON], params: [String: TasksJSON]) {
        guard fd >= 0 else { return }
        struct Line: Encodable {
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
        guard var data = try? JSONEncoder().encode(Line(fields: fields, params: params)) else { return }
        data.append(UInt8(ascii: "\n"))
        // Lines are small; a local stream socket takes them whole.
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }
}
