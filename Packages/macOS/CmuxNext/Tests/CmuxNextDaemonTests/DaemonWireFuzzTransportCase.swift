import CmuxFuzzSupport
import Darwin
import Foundation
@testable import CmuxNextDaemon

/// One connection's script: `requests` pipelined requests (ids 1...requests), then the peer's lines cut into
/// chunks. The model routes each line by the contract in ``LineTransport``'s comments: an event (a stream
/// line too, with no stream handler set) is counted and goes to `onEvent`; a reply resolves its id, or the
/// oldest pending request when it has no usable id, if that request is still pending, and is dropped
/// otherwise; an unfinished last line is never read; EOF fails what is left, as a shutdown once a
/// `daemon-shutdown` event came.
struct WireFuzzTransportCase {
    static let command = "fuzz"
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
                if case .command(WireFuzzTransportCase.command, let message, _, _, _) = error {
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

    struct Expected {
        var results: [Outcome] = []
        var events: [Seen] = []
        var close: TransportCloseReason = .lost("EOF")
    }

    let requests: Int
    let lines: [WireFuzzLine]
    let terminated: Bool
    let chunks: [[UInt8]]

    init(_ rng: inout FuzzRNG) throws {
        let requests = rng.below(6)
        var lines: [WireFuzzLine] = []
        for _ in 0..<rng.below(28) {
            lines.append(try WireFuzzLine.random(&rng, requests: requests))
        }
        let terminated = !rng.oneIn(5)
        var stream = lines.flatMap { $0.bytes + [0x0A] }
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
    }

    func expected() -> Expected {
        var pending = (0..<requests).map { UInt64($0 + 1) }
        var outcomes: [UInt64: Outcome] = [:]
        var expected = Expected()
        var sawShutdown = false
        // An unterminated last line stays in the splitter.
        let read = terminated ? lines[...] : lines.dropLast()
        for line in read {
            switch line.route {
            case .ignored:
                continue
            case .event(let name):
                expected.events.append(Seen(name: name, line: line.bytes, index: UInt64(expected.events.count + 1)))
                if name == "daemon-shutdown" { sawShutdown = true }
            case .stream:
                expected.events.append(Seen(name: LineTransport.streamEvent, line: line.bytes, index: UInt64(expected.events.count + 1)))
            case .reply(let id, let ok, let message):
                guard let target = id ?? pending.first, let slot = pending.firstIndex(of: target) else { continue }
                pending.remove(at: slot)
                let outcome: Outcome = ok == true
                    ? .success(line: line.bytes, barrier: UInt64(expected.events.count))
                    : .command(message: message ?? "unknown error")
                outcomes[target] = outcome
            }
        }
        expected.close = sawShutdown ? .daemonShutdown : .lost("EOF")
        let closed: DaemonError = sawShutdown ? .daemonShutdown : .connectionClosed(reason: "EOF")
        expected.results = (0..<requests).map { outcomes[UInt64($0 + 1)] ?? .closed(closed) }
        return expected
    }

    /// Runs the case on a thread that may block (it waits for the reader thread).
    func run(on peer: WireFuzzPeer) throws {
        peer.serve(requestLines: requests, chunks: chunks)
        let transport = try LineTransport(path: peer.path, role: .control, stats: nil)
        defer { transport.close() }
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
                PipelinedLine(cmd: command) { id in Data(#"{"cmd":"\#(command)","id":\#(id)}"#.utf8) }
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
    }

    func describe() -> String {
        let shown = lines.map { String(decoding: $0.bytes.prefix(120), as: UTF8.self) }.joined(separator: " | ")
        return "\(requests) requests, \(chunks.count) chunks, terminated \(terminated), lines: \(shown)"
    }
}

/// A Unix socket served by this process: each `serve` accepts one connection, reads the client's request
/// lines, writes the script chunk by chunk and closes it.
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

    func serve(requestLines: Int, chunks: [[UInt8]]) {
        let listener = listener
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
            for chunk in chunks where !Self.writeAll(chunk, to: client) { return }
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
