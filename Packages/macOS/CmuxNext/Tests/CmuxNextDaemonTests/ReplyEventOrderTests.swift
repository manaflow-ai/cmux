import CmuxNextCompat
@testable import CmuxNextDaemon
import Darwin
import Foundation
import Testing

/// The app side of the reply/event order rule (cmux-tui/spec/transports.md
/// "Reply and event order"): a reply's `eventBarrier` and
/// `routedEventCount` count only the control sequence's events (stream 0),
/// so the items of other streams on the connection never move the barrier.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ReplyEventOrderTests {
    /// One accepted connection of a fake daemon on a Unix socket in `/tmp`.
    final class FakeDaemon {
        let path = "/tmp/cmux-reo-\(UUID().uuidString.prefix(8)).sock"
        private var listener: Int32 = -1
        private var peer: Int32 = -1

        init() throws {
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = path
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8)
                buffer[path.utf8.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
        }

        deinit {
            if peer >= 0 { close(peer) }
            if listener >= 0 { close(listener) }
            unlink(path)
        }

        /// Accepts the transport's connection (already queued by its connect).
        func accept() throws {
            peer = Darwin.accept(listener, nil, nil)
            guard peer >= 0 else { throw POSIXError(.ECONNABORTED) }
        }

        /// Reads one request line and returns its `id`.
        func readRequestID() throws -> UInt64 {
            var line = Data()
            var byte: UInt8 = 0
            while byte != 0x0A {
                guard read(peer, &byte, 1) == 1 else { throw POSIXError(.ECONNRESET) }
                line.append(byte)
            }
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
            return try #require((object?["id"] as? NSNumber)?.uint64Value)
        }

        func write(_ lines: [String]) {
            var bytes = Array(lines.joined(separator: "\n").utf8)
            bytes.append(0x0A)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    /// Every line the transport gave `onEvent`, with its index.
    final class Routed: Sendable {
        let lines = Mutex<[(name: String, index: UInt64)]>([])
        let arrivals: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() {
            let (arrivals, continuation) = AsyncStream<Void>.makeStream()
            self.arrivals = arrivals
            self.continuation = continuation
        }

        func record(_ name: String, _ index: UInt64) {
            lines.withLock { $0.append((name, index)) }
            continuation.yield()
        }

        func waitFor(_ count: Int) async {
            var seen = 0
            for await _ in arrivals {
                seen += 1
                if seen == count { return }
            }
        }
    }

    static let streams = (0..<10).map { "stream_\(String(repeating: "0", count: 31))\($0)" }

    /// `rounds` items on each of the ten streams, interleaved.
    static func streamItems(rounds: Int, from first: Int) -> [String] {
        (first..<first + rounds).flatMap { round in
            streams.map { #"{"type":"stream_item","stream_id":"\#($0)","sequence":\#(round),"item":{"n":\#(round)}}"# }
        }
    }

    @Test func aReplyBarrierCoversItsEchoAndIgnoresTenStreams() async throws {
        let daemon = try FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        let routed = Routed()
        transport.start(onEvent: { name, _, index in routed.record(name, index) }, onClose: { _ in })
        defer { transport.close() }

        let reply = Task {
            try await transport.request(cmd: "new-tab", timeout: nil) { id in Data(#"{"id":\#(id),"cmd":"new-tab"}"#.utf8) }
        }
        let id = try daemon.readRequestID()
        let before = Self.streamItems(rounds: 3, from: 0)
        let between = Self.streamItems(rounds: 2, from: 3)
        let after = Self.streamItems(rounds: 2, from: 5)
        // The sentinel, a raw event after everything, tells the test the reader is done.
        daemon.write(before + [#"{"event":"tree-changed"}"#] + between + [#"{"id":\#(id),"ok":true,"data":{}}"#]
                     + after + [#"{"event":"sentinel"}"#])
        let response = try await reply.value
        await routed.waitFor(2)

        let lines = routed.lines.withLock { $0 }
        let echo = try #require(lines.first { $0.name == "tree-changed" })
        #expect(response.eventBarrier >= echo.index, "the reply's barrier misses its echo")
        #expect(DaemonEventEnvelope.sequence(serial: 1, index: response.eventBarrier)
                    >= DaemonEventEnvelope.sequence(serial: 1, index: echo.index))
        #expect(echo.index == 1, "stream items before the echo moved its index")
        #expect(response.eventBarrier == 1, "stream items moved the reply's barrier")
        #expect(transport.routedEventCount == 2, "stream items changed routedEventCount")
        #expect(lines.map(\.name) == ["tree-changed", "sentinel"], "an unregistered stream's line reached onEvent")
    }

    @Test func aControlSequenceStreamCountsUntilItsEnd() async throws {
        let daemon = try FakeDaemon()
        let transport = try LineTransport(path: daemon.path, role: .control, stats: nil)
        try daemon.accept()
        let routed = Routed()
        transport.start(onEvent: { name, _, index in routed.record(name, index) }, onClose: { _ in })
        defer { transport.close() }
        let session = "stream_\(String(repeating: "f", count: 32))"
        transport.routeOnControlSequence(streamID: session)

        let reply = Task {
            try await transport.request(cmd: "session.events", timeout: nil) { id in Data(#"{"id":\#(id),"cmd":"x"}"#.utf8) }
        }
        let id = try daemon.readRequestID()
        let item = #"{"type":"stream_item","stream_id":"\#(session)","sequence":1,"item":{}}"#
        let end = #"{"type":"stream_end","stream_id":"\#(session)","reason":"gap"}"#
        let others = Self.streamItems(rounds: 1, from: 0)
        daemon.write([item] + others + [#"{"id":\#(id),"ok":true,"data":{}}"#, end, item, #"{"event":"sentinel"}"#])
        let response = try await reply.value
        await routed.waitFor(3)

        #expect(response.eventBarrier == 1, "the control stream's item is in the barrier")
        #expect(transport.routedEventCount == 3, "its end counts; a line after the end is dropped")
        let lines = routed.lines.withLock { $0 }
        // Every delivered line has its own index: none reaches the store under another's sequence.
        #expect(lines.map(\.index) == [1, 2, 3])
        #expect(lines.map(\.name) == [LineTransport.streamEvent, LineTransport.streamEvent, "sentinel"])
    }
}
