import CmuxNextCompat
import Darwin
public import Foundation

/// The running `cmux cloud codex-holder` child: JSON lines in on its stdin, its stdout lines out as
/// ``Event``s. One writer (``CloudCodexHolder``'s send loop) calls ``send(_:acpmux:)`` at a time.
/// Credentials never go in argv: only `cloud codex-holder` does.
actor CloudCodexHolderPipe {
    /// A line for the child. `id` is a request the child will answer; `answerFor` is the child
    /// generation an answer belongs to (dropped when that child is gone); `available` is the
    /// policy fence, sent again to a new child.
    struct Line: Sendable {
        var data: Data
        var id: Int?
        var answerFor: Int?
        var available: Bool?
    }

    enum Event: Sendable {
        /// One stdout line of child `generation`.
        case line(generation: Int, Data)
        /// Child `generation` ended; `ids` are the requests it never answered.
        case ended(generation: Int, ids: Set<Int>)
    }

    private let binary: URL
    private let config: Data
    private let events: AsyncStream<Event>.Continuation
    private var process: Process?
    private var input: FileHandle?
    private var stopReading: (@Sendable () -> Void)?
    private var generation = 0
    private var sent: Set<Int> = []
    private var available = true
    /// What the running holder knows, replayed into the next one (``replay``): the scopes it
    /// served, the current scope it last held and the live machines of the last list. Without it
    /// a holder started again could not erase what the last one delivered.
    private var known = Known()

    private struct Known {
        var scopes: [String: [String: Any]] = [:]
        var current: [String: Any]?
        var live: [String] = []
    }

    init(binary: URL, config: Data, events: AsyncStream<Event>.Continuation) {
        self.binary = binary
        self.config = config
        self.events = events
    }

    deinit {
        events.finish()
        stopReading?()
        try? input?.close()
    }

    var isRunning: Bool { process != nil }

    /// Writes `line`, starting the child first when none runs (`acpmux` is the holder child's
    /// executable, sent to a new child). False when the child cannot start or take the line.
    func send(_ line: Line, acpmux: URL?) -> Bool {
        if let available = line.available { self.available = available }
        if let owner = line.answerFor {
            // An answer for a child that ended: the new child never asked it.
            guard owner == generation, process != nil else { return true }
        }
        if process == nil, !start(acpmux: acpmux) { return false }
        guard write(line.data) else { return false }
        if let id = line.id { sent.insert(id) }
        if line.answerFor == nil { remember(line.data) }
        return true
    }

    /// Notes what a line told the holder. Answers carry none of it.
    private func remember(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let current = object["current"] {
            known.current = current as? [String: Any]
            if let scope = known.current { known.scopes[Self.key(scope)] = scope }
        }
        if let scope = object["scope"] as? [String: Any] { known.scopes[Self.key(scope)] = scope }
        if object["op"] as? String == "listed", let live = object["live"] as? [String] { known.live = live }
    }

    private static func key(_ scope: [String: Any]) -> String {
        "\((scope["user"] as? String ?? "").utf8.count):\(scope["user"] as? String ?? "")|\(scope["team"] as? String ?? "\u{0}")"
    }

    /// The `restore` line for a holder started again: what the last one knew, under the current
    /// scope it held. Nil for the first holder (nothing to replay).
    private func replay() -> Data? {
        guard !known.scopes.isEmpty || !known.live.isEmpty else { return nil }
        let fields: [String: Any] = [
            "op": "restore", "scopes": Array(known.scopes.values), "live": known.live,
            "current": known.current ?? NSNull(),
        ]
        return try? JSONSerialization.data(withJSONObject: fields)
    }

    /// The generation of the running child (answers are tagged with it).
    var current: Int { generation }

    private func write(_ data: Data) -> Bool {
        guard let input else { return false }
        var line = data
        line.append(0x0A)
        do { try input.write(contentsOf: line) } catch { return false }
        return true
    }

    private func start(acpmux: URL?) -> Bool {
        let inputPipe = Pipe(), outputPipe = Pipe()
        let writer = inputPipe.fileHandleForWriting
        // Close-on-exec: no other child of the app inherits the holder's stdin; a child that
        // exits makes a write fail (EPIPE), never SIGPIPE the app.
        _ = fcntl(writer.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(outputPipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["cloud", "codex-holder"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        generation += 1
        sent = []
        self.process = process
        self.input = writer
        let (chunks, stop) = outputPipe.fileHandleForReading.readyChunks()
        stopReading = stop
        let child = generation, events = events
        // task-owner: the reader ends at the child's end of file, a failed read, or deinit (stop).
        Task { [weak self] in
            var buffer = Data()
            reading: for await chunk in chunks {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                    // A holder the app cannot keep up with is ended: what it had not answered fails.
                    if !line.isEmpty, case .dropped = events.yield(.line(generation: child, line)) { break reading }
                }
                // A line this long is not the holder's: end the child rather than hold it.
                if buffer.count > 1 << 20 { break reading }
            }
            await self?.ended(child)
        }
        var opening = [config]
        var hello: [String: Any] = ["op": "available", "enabled": available]
        if let acpmux { hello["acpmux"] = acpmux.path }
        if let data = try? JSONSerialization.data(withJSONObject: hello) { opening.append(data) }
        // Config, availability, then what the last holder knew, before any line the app sends now.
        if let restore = replay() { opening.append(restore) }
        return opening.allSatisfy { write($0) }
    }

    private func ended(_ child: Int) {
        guard child == generation, let process else { return }
        stopReading?()
        stopReading = nil
        try? input?.close()
        input = nil
        // Signal only the child this pipe launched, by its own handle.
        if process.isRunning { process.terminate() }
        self.process = nil
        let ids = sent
        sent = []
        events.yield(.ended(generation: child, ids: ids))
    }
}
