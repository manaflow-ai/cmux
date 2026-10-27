import CmuxFuzzSupport
import Darwin
import Foundation
@testable import CmuxNextDaemon
@testable import CmuxNextTrace

/// One connection's script: `requests` pipelined requests (ids 1...requests), the control streams it opens
/// and whether it sets a stream handler, then the peer's lines cut into chunks the reader reads one at a
/// time. The model routes each line by the contract in ``LineTransport``'s comments: an event is counted and
/// goes to `onEvent`; a stream line with no `stream_id` is such an event too, one of a control stream
/// (`routeOnControlSequence`) as well until that stream's `stream_end`, any other goes to the stream handler
/// or is dropped when there is none; a reply resolves its id, or the oldest pending request when it has no
/// usable id, if that request is still pending, and is dropped otherwise; an unfinished last line is never
/// read; EOF fails what is left, as a shutdown once a `daemon-shutdown` event came.
struct WireFuzzTransportCase {
    static let command: DaemonCommandName = "fuzz"
    static let hangLimit: DispatchTimeInterval = .seconds(20)

    /// What the transport gave one request.
    enum Outcome: Equatable, Sendable, CustomStringConvertible {
        case success(line: [UInt8], barrier: UInt64)
        case command(message: String)
        case closed(DaemonError)
        case other(String)

        init(_ result: Result<LineTransport.Response, any Error>) {
            switch result {
            case .success(let response):
                self = .success(line: [UInt8](response.line), barrier: response.eventBarrier)
            case .failure(let error as DaemonError):
                if case .command(WireFuzzTransportCase.command.wire, let message, _, _, _) = error {
                    self = .command(message: message)
                } else {
                    self = .closed(error)
                }
            case .failure(let error):
                self = .other(String(describing: error))
            }
        }

        var description: String {
            switch self {
            case .success(let line, let barrier): "ok(\(line.count) bytes, barrier \(barrier))"
            case .command(let message): "error(\(message))"
            case .closed(let error): "closed(\(error))"
            case .other(let text): "untyped(\(text))"
            }
        }
    }

    struct Seen: Equatable, Sendable {
        var name: String
        var line: [UInt8]
        var index: UInt64
    }

    /// A line the stream handler got.
    struct Handled: Equatable, Sendable {
        var streamID: String
        var line: [UInt8]
    }

    struct Expected {
        var results: [Outcome] = []
        var events: [Seen] = []
        var handled: [Handled] = []
        var close: TransportCloseReason = .lost("EOF")
        /// Non-empty lines the reader cuts (an unfinished last line is not one).
        var linesRead: UInt64 = 0
        var coverage = WireFuzzTransportCoverage()
    }

    let requests: Int
    let lines: [WireFuzzLine]
    let terminated: Bool
    let chunks: [[UInt8]]
    /// Stream ids routed as stream-0 events (`routeOnControlSequence`) before the reader starts.
    let controlStreams: Set<String>
    /// Whether the case sets a stream handler.
    let handlesStreams: Bool

    init(_ rng: inout FuzzRNG) throws {
        let requests = rng.below(6)
        var lines: [WireFuzzLine] = []
        for _ in 0..<rng.below(28) {
            lines.append(try WireFuzzLine.random(&rng, requests: requests))
        }
        let terminated = !rng.oneIn(5)
        var stream: [UInt8] = lines.flatMap { $0.bytes + [0x0A] }
        if !terminated, !stream.isEmpty { stream.removeLast() }
        var chunks: [[UInt8]] = []
        let tiny = stream.count < 4096 && rng.oneIn(4)
        var at = 0
        while at < stream.count {
            let left = stream.count - at
            let count = tiny ? min(left, 1 + rng.below(3)) : 1 + rng.below(left)
            chunks.append(Array(stream[at..<(at + count)]))
            at += count
        }
        self.requests = requests
        self.lines = lines
        self.terminated = terminated
        self.chunks = chunks
        var controlStreams: Set<String> = []
        for streamID in WireFuzzLine.streamIDs where rng.oneIn(2) { controlStreams.insert(streamID) }
        self.controlStreams = controlStreams
        handlesStreams = rng.bool()
    }

    func expected() -> Expected {
        var pending = (0..<requests).map { UInt64($0 + 1) }
        var outcomes: [UInt64: Outcome] = [:]
        var expected = Expected()
        var control = controlStreams
        var sawShutdown = false
        // An unterminated last line stays in the reader.
        let read = terminated ? lines[...] : lines.dropLast()
        for line in read {
            if !line.bytes.isEmpty { expected.linesRead += 1 }
            let event = Seen(name: LineTransport.streamEvent, line: line.bytes, index: UInt64(expected.events.count + 1))
            switch line.route {
            case .ignored:
                continue
            case .event(let name):
                expected.events.append(Seen(name: name, line: line.bytes, index: event.index))
                expected.coverage.events += 1
                if name == "daemon-shutdown" {
                    sawShutdown = true
                    expected.coverage.shutdowns += 1
                }
            case .stream(_, nil):
                expected.events.append(event)
                expected.coverage.unscopedStreamEvents += 1
            case .stream(let type, let streamID?):
                if control.contains(streamID) {
                    if type == "stream_end" { control.remove(streamID) }
                    expected.events.append(event)
                    expected.coverage.controlStreamEvents += 1
                } else if handlesStreams {
                    expected.handled.append(Handled(streamID: streamID, line: line.bytes))
                    expected.coverage.handledStreamLines += 1
                } else {
                    expected.coverage.droppedStreamLines += 1
                }
            case .reply(let id, let ok, let message):
                guard let target = id ?? pending.first, let slot = pending.firstIndex(of: target) else {
                    expected.coverage.droppedReplies += 1
                    continue
                }
                pending.remove(at: slot)
                if ok == true {
                    outcomes[target] = .success(line: line.bytes, barrier: UInt64(expected.events.count))
                    expected.coverage.successes += 1
                } else {
                    outcomes[target] = .command(message: message ?? "unknown error")
                    expected.coverage.commandErrors += 1
                }
            }
        }
        expected.close = sawShutdown ? .daemonShutdown : .lost("EOF")
        let closed: DaemonError = sawShutdown ? .daemonShutdown : .connectionClosed(reason: "EOF")
        expected.results = (0..<requests).map { outcomes[UInt64($0 + 1)] ?? .closed(closed) }
        expected.coverage.unresolved = pending.count
        expected.coverage.unterminated = terminated || lines.isEmpty ? 0 : 1
        return expected
    }

    /// Runs the case on a thread that may block (it waits for the reader thread); returns the routes it took.
    func run(on peer: WireFuzzPeer) throws -> WireFuzzTransportCoverage {
        let stats = DaemonWireStats()
        let routedLines = WireFuzzRoutedLines()
        peer.serve(requestLines: requests, chunks: chunks, routedLines: routedLines)
        // Its own runtime, so its own request ids: the script names this connection's requests 1...requests.
        let transport = try LineTransport(path: peer.path, role: .control, stats: stats, hangs: routedLines,
                                          trace: TraceRuntime(role: .app))
        defer { transport.close() }
        for streamID in controlStreams.sorted() { transport.routeOnControlSequence(streamID: streamID) }
        let handled = WireFuzzLocked<[Handled]>([])
        if handlesStreams {
            transport.setStreamHandler { streamID, line in
                handled.withLock { $0.append(Handled(streamID: streamID, line: [UInt8](line))) }
            }
        }
        let events = WireFuzzLocked<[Seen]>([])
        let close = WireFuzzLocked<TransportCloseReason?>(nil)
        let closed = DispatchSemaphore(value: 0)
        transport.start(
            onEvent: { name, line, index in events.withLock { $0.append(Seen(name: name, line: [UInt8](line), index: index)) } },
            onClose: { reason in
                close.withLock { $0 = reason }
                closed.signal()
            }
        )
        let replies = WireFuzzLocked<[Outcome]?>(nil)
        let replied = DispatchSemaphore(value: 0)
        let requests = self.requests
        let command = Self.command
        // task-owner: one per case; it ends when the reader resolves every slot, at the latest at EOF.
        Task {
            let lines = (0..<requests).map { _ in
                PipelinedLine(cmd: command) { id in Data(#"{"cmd":"\#(command.wire)","id":\#(id)}"#.utf8) }
            }
            let results = await transport.pipeline(lines, timeout: nil)
            replies.withLock { $0 = results.map(Outcome.init) }
            replied.signal()
        }
        try FuzzRun.check(closed.wait(timeout: .now() + Self.hangLimit) == .success, "the reader did not reach EOF: \(describe())")
        try FuzzRun.check(replied.wait(timeout: .now() + Self.hangLimit) == .success, "a request never resolved: \(describe())")

        let want = expected()
        let got = replies.withLock { $0 } ?? []
        try FuzzRun.check(got == want.results, "replies \(got), the model \(want.results): \(describe())")
        let seen = events.withLock { $0 }
        try FuzzRun.check(seen == want.events,
                          "events \(seen.map(\.name)) at \(seen.map(\.index)), the model \(want.events.map(\.name)): \(describe())")
        let reason = close.withLock { $0 }
        try FuzzRun.check(reason == want.close, "closed with \(String(describing: reason)), the model \(want.close): \(describe())")
        try FuzzRun.check(transport.routedEventCount == UInt64(want.events.count), "routed \(transport.routedEventCount) events: \(describe())")
        let streamed = handled.withLock { $0 }
        try FuzzRun.check(streamed == want.handled,
                          "the stream handler got \(streamed.map(\.streamID)), the model \(want.handled.map(\.streamID)): \(describe())")
        let counted = stats.snapshot()
        let sent = UInt64(chunks.reduce(0) { $0 + $1.count })
        try FuzzRun.check(counted.bytesRead == sent, "read \(counted.bytesRead) of \(sent) bytes: \(describe())")
        try FuzzRun.check(counted.linesRead == want.linesRead, "cut \(counted.linesRead) lines, the model \(want.linesRead): \(describe())")
        return want.coverage
    }

    func describe() -> String {
        let shown = lines.map { String(decoding: $0.bytes.prefix(120), as: UTF8.self) }.joined(separator: " | ")
        return "\(requests) requests, \(chunks.count) chunks, terminated \(terminated), "
            + "control streams \(controlStreams.sorted()), stream handler \(handlesStreams), lines: \(shown)"
    }
}

/// How often each route came up over a run's cases, so a generator that stops making a kind of line fails.
struct WireFuzzTransportCoverage: Sendable {
    var successes = 0
    var commandErrors = 0
    var unresolved = 0
    var droppedReplies = 0
    var events = 0
    var shutdowns = 0
    var unscopedStreamEvents = 0
    var controlStreamEvents = 0
    var handledStreamLines = 0
    var droppedStreamLines = 0
    var unterminated = 0

    mutating func add(_ other: WireFuzzTransportCoverage) {
        successes += other.successes
        commandErrors += other.commandErrors
        unresolved += other.unresolved
        droppedReplies += other.droppedReplies
        events += other.events
        shutdowns += other.shutdowns
        unscopedStreamEvents += other.unscopedStreamEvents
        controlStreamEvents += other.controlStreamEvents
        handledStreamLines += other.handledStreamLines
        droppedStreamLines += other.droppedStreamLines
        unterminated += other.unterminated
    }

    /// The routes no case took.
    var missing: [String] {
        let counts: KeyValuePairs<String, Int> = [
            "ok reply": successes, "error reply": commandErrors, "request failed at EOF": unresolved,
            "dropped reply": droppedReplies, "event": events, "daemon-shutdown": shutdowns,
            "stream line with no stream_id": unscopedStreamEvents, "control stream line": controlStreamEvents,
            "stream handler line": handledStreamLines, "dropped stream line": droppedStreamLines,
            "unfinished last line": unterminated,
        ]
        return counts.filter { $0.value == 0 }.map { $0.key }
    }
}

/// The reader's line scope (``LineTransport``'s `hangs` seam): it counts each line the reader routed, so the
/// peer can wait for the reader without polling. The writer's `daemon.write` steps share the seam and are
/// not counted.
final class WireFuzzRoutedLines: HangWatchScoping {
    private let routed = DispatchSemaphore(value: 0)
    /// The slot of the reader's `daemon.line` lane; every other lane gets slot 1.
    private static let lineSlot: UInt32 = 0

    func registerLane(_ name: StaticString) -> HangWatch.Registration {
        HangWatch.Registration(slot: name.description == "daemon.line" ? Self.lineSlot : 1, generation: 1)
    }

    func unregister(_ registration: HangWatch.Registration) {}

    func watch<T>(_ registration: HangWatch.Registration, deadline: Duration, _ body: () throws -> T) rethrows -> T {
        defer { if registration.slot == Self.lineSlot { routed.signal() } }
        return try body()
    }

    /// Waits until the reader routed one more line; false when `timeout` passes first.
    func waitForOne(timeout: DispatchTimeInterval) -> Bool {
        routed.wait(timeout: .now() + timeout) == .success
    }
}

/// A Unix socket served by this process: each `serve` accepts one connection, reads the client's request
/// lines, writes the script chunk by chunk, pacing it by the lines the reader routed, and closes it.
final class WireFuzzPeer: Sendable {
    enum PeerError: Error, CustomStringConvertible {
        case socket(String, errno: Int32)

        var description: String {
            switch self {
            case .socket(let call, let code): "\(call): \(String(cString: strerror(code)))"
            }
        }
    }

    let path: String
    private let listener: Int32

    init() throws(PeerError) {
        let path = "/tmp/cnd-wfz-\(UUID().uuidString.prefix(8).lowercased()).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw .socket("socket", errno: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else {
            let code = errno
            close(listener)
            throw .socket("bind/listen \(path)", errno: code)
        }
        self.path = path
        self.listener = listener
    }

    /// How long the peer waits for the reader to route a chunk's lines; past it the peer stops pacing and the
    /// case's own hang limit reports the reader.
    static let pacingLimit: DispatchTimeInterval = .seconds(5)

    /// The non-empty lines that end in each chunk or before it: what the reader has routed once it read the chunk.
    static func linesEnded(by chunks: [[UInt8]]) -> [Int] {
        var lines = 0
        var lineHasBytes = false
        return chunks.map { chunk in
            for byte in chunk {
                if byte != 0x0A {
                    lineHasBytes = true
                } else if lineHasBytes {
                    lines += 1
                    lineHasBytes = false
                }
            }
            return lines
        }
    }

    func serve(requestLines: Int, chunks: [[UInt8]], routedLines: WireFuzzRoutedLines) {
        let listener = listener
        let linesEnded = Self.linesEnded(by: chunks)
        let thread = Thread {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let capacity = 4096
            var buffer = [UInt8](repeating: 0, count: capacity)
            var newlines = 0
            while newlines < requestLines {
                let count = recv(client, &buffer, capacity, 0)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return }
                newlines += buffer.prefix(count).filter { $0 == 0x0A }.count
            }
            // A chunk that ends a line is written only after the reader routed every line before it, so the
            // reader's read(2) stops at that chunk's end and a cut line waits in its reader for the next one.
            var waited = 0
            var paced = true
            for (chunk, ended) in zip(chunks, linesEnded) {
                guard Self.writeAll(chunk, to: client) else { return }
                while paced, waited < ended {
                    paced = routedLines.waitForOne(timeout: Self.pacingLimit)
                    waited += 1
                }
            }
        }
        thread.name = "DaemonWireFuzz peer"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
        unlink(path)
    }

    private static func writeAll(_ bytes: [UInt8], to fd: Int32) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }
}
