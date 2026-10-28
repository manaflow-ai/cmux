import CmuxNextCompat
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// Scale and abuse (pro audit 14): a large paste must neither cost the connection nor leave it half closed.
/// cmux-tui reads a JSON line of at most 16 MiB (`MAX_JSON_LINE_BYTES`, cmux-tui-core server.rs) and ends the
/// connection on a longer one (`line_too_long`); the app's writer queues at most 64 MiB
/// (``FrameWriter/defaultLimit``). A 13 MiB paste went out as one 17 MiB `send` line, so the daemon dropped the
/// connection and the paste with it; a 50 MiB paste passed the writer's limit, after which every request on the
/// transport failed as closed while its socket stayed open and its reader kept delivering output, so no close
/// ever reached the owner and nothing reconnected.
@Suite(.serialized, .timeLimit(.minutes(1))) struct OversizeInputTests {
    typealias FakeDaemon = ReplyEventOrderTests.FakeDaemon

    /// The daemon's JSON line limit, its `\n` excluded.
    static let daemonLineLimit = 16 << 20

    /// Reads whole lines from the fake daemon's peer in large reads (a byte per read takes minutes for 20 MiB).
    final class LineReader: @unchecked Sendable {  // read by one task only, after its init
        private let fd: Int32
        private var buffer: [UInt8] = []

        init(fd: Int32) { self.fd = fd }

        /// The next line without its `\n`; nil at end of stream.
        func next() -> [UInt8]? {
            var scanned = 0
            while true {
                if let newline = buffer[scanned...].firstIndex(of: 0x0A) {
                    let line = Array(buffer[..<newline])
                    buffer.removeFirst(newline + 1)
                    return line
                }
                scanned = buffer.count
                var chunk = [UInt8](repeating: 0, count: 1 << 20)
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[..<count])
            }
        }
    }

    private static func line(_ id: UInt64, _ cmd: String, padding: Int = 0) -> Data {
        Data(#"{"id":\#(id),"cmd":"\#(cmd)","pad":"\#(String(repeating: "a", count: padding))"}"#.utf8)
    }

    private func connect(_ daemon: FakeDaemon, onClose: @escaping LineTransport.CloseHandler = { _ in }) throws -> LineTransport {
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        // A line that never comes fails the test after 20 s instead of blocking its read(2) for good.
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(daemon.peerDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        transport.start(onEvent: { _, _, _ in }, onClose: onClose)
        return transport
    }

    /// A request line longer than the daemon reads fails alone, before it reaches the wire: the next request goes
    /// out first and is answered on the same connection.
    @Test func aRequestLineOverTheDaemonLimitFailsAloneAndTheConnectionStays() async throws {
        let daemon = try FakeDaemon()
        let transport = try connect(daemon)
        defer { transport.close() }
        let big = Task {
            try await transport.request(cmd: DaemonCommandName(wire: "big"), timeout: .seconds(2)) {
                Self.line($0, "big", padding: Self.daemonLineLimit)
            }
        }
        let outcome = await big.result
        guard case .failure(let error) = outcome, case .command(_, _, let code, _, _)? = error as? DaemonError else {
            Issue.record("the oversize request ended with \(outcome), not a refusal of its own")
            return
        }
        #expect(code == "request_too_large")
        #expect(!transport.isClosed, "one oversize request closed the connection")

        let small = Task { try await transport.request(cmd: DaemonCommandName(wire: "small"), timeout: .seconds(5)) { Self.line($0, "small") } }
        let request = try daemon.readRequest()
        #expect(request["cmd"] as? String == "small", "the oversize line went out before the next request")
        daemon.write([#"{"id":\#((request["id"] as? NSNumber)?.uint64Value ?? 0),"ok":true,"data":{}}"#])
        _ = try await small.value
    }

    /// A write the writer refuses (the daemon stopped reading and 64 MiB wait) closes the transport for good: its
    /// socket shuts down, the reader ends and the owner hears the close, so it reconnects. Before, the transport
    /// only marked itself closed and kept its socket and reader, and the owner never heard of it.
    @Test func aWriteTheWriterRefusesClosesTheConnectionAndTheOwnerHearsIt() async throws {
        let daemon = try FakeDaemon()
        let (closes, closed) = AsyncStream<TransportCloseReason>.makeStream()
        let transport = try connect(daemon, onClose: { closed.yield($0) })
        defer { transport.close() }
        // The fake daemon reads nothing: 6 lines of 15 MiB pass the writer's 64 MiB, a few hundred KiB of socket
        // buffers aside.
        var refused = false
        for _ in 0..<6 where !refused {
            do {
                try transport.sendNoReply(cmd: "fill") { Self.line($0, "fill", padding: 15 << 20) }
            } catch {
                refused = true
            }
        }
        #expect(refused, "the writer took 90 MiB from a daemon that reads nothing")
        let heard = Task { () -> TransportCloseReason? in
            for await reason in closes { return reason }
            return nil
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            heard.cancel()
        }
        defer { timeout.cancel() }
        let reason = await heard.value
        #expect(reason != nil, "the transport refused a write but its owner never heard a close")
        #expect(transport.isClosed)
    }

    /// A stream line (`loopback-data`) the writer refuses ends the connection the same way, so the loopback
    /// stream's owner reconnects instead of failing every later line on a socket that stays open.
    @Test func aStreamLineTheWriterRefusesClosesTheConnection() async throws {
        let daemon = try FakeDaemon()
        let (closes, closed) = AsyncStream<TransportCloseReason>.makeStream()
        let transport = try connect(daemon, onClose: { closed.yield($0) })
        defer { transport.close() }
        var refused = false
        for _ in 0..<6 where !refused {
            refused = !transport.sendLine(Data(String(repeating: "b", count: 15 << 20).utf8))
        }
        #expect(refused, "the writer took 90 MiB from a daemon that reads nothing")
        let heard = Task { () -> TransportCloseReason? in
            for await reason in closes { return reason }
            return nil
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            heard.cancel()
        }
        defer { timeout.cancel() }
        #expect(await heard.value != nil, "a refused stream line left the connection open with no close")
    }

    /// Terminal input travels in `send` lines the daemon reads: a 20 MiB paste reaches it whole, in order, and no
    /// line passes the daemon's limit.
    @Test func aLargePasteReachesTheDaemonInLinesItReads() async throws {
        let daemon = try FakeDaemon()
        let transport = try connect(daemon)
        defer { transport.close() }
        let attachment = TerminalAttachment(transport: transport, surface: SurfaceID(rawValue: 7))
        var paste = Data(count: 20 << 20)
        paste.withUnsafeMutableBytes { raw in
            for index in raw.indices { raw[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 13) }
        }
        let expected = paste
        let reader = LineReader(fd: daemon.peerDescriptor)
        let received = Task.detached { () -> (Data, Int) in
            var bytes = Data()
            var longest = 0
            while bytes.count < expected.count, let line = reader.next() {
                longest = max(longest, line.count)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["cmd"] as? String == "send", let encoded = object["bytes"] as? String,
                      let chunk = Data(base64Encoded: encoded) else { break }
                bytes.append(chunk)
                // A line over the daemon's limit ends the connection there: nothing after it is read.
                if line.count > Self.daemonLineLimit { break }
            }
            return (bytes, longest)
        }
        attachment.enqueueInput(paste)
        let (bytes, longest) = await received.value
        #expect(longest <= Self.daemonLineLimit, "a send line of \(longest) bytes passes the daemon's \(Self.daemonLineLimit)")
        #expect(bytes == expected, "the daemon got \(bytes.count) of \(expected.count) pasted bytes, or out of order")
    }

    /// A paste larger than the writer takes (64 MiB of lines) is refused whole: no first part of it reaches the
    /// program, and the connection stays for the next key.
    @Test func aPasteTheWriterCannotTakeIsRefusedWholeAndTheConnectionStays() async throws {
        let daemon = try FakeDaemon()
        let transport = try connect(daemon)
        defer { transport.close() }
        let attachment = TerminalAttachment(transport: transport, surface: SurfaceID(rawValue: 7))
        attachment.enqueueInput(Data(repeating: 0x61, count: 60 << 20))
        #expect(!transport.isClosed, "a paste over the writer's room closed the connection")
        attachment.enqueueInput(Data("k".utf8))
        let request = try daemon.readRequest()
        #expect(request["cmd"] as? String == "send")
        #expect((request["bytes"] as? String).flatMap { Data(base64Encoded: $0) } == Data("k".utf8),
                "part of the refused paste reached the daemon before the next key")
    }
}
