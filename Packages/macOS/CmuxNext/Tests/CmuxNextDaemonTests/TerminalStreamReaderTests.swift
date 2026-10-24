import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A view's stream on the shared connection never splices output across a
/// break: a gap in the stream's offsets drops output until a fresh READY and
/// asks for one on the view's own stream lane (design section 3.4).
@Suite struct TerminalStreamReaderTests {
    private struct Fixture {
        let reader: TerminalStreamReader
        let queue: TerminalEventQueue
        let transport: LineTransport
        /// The daemon's end of the socket: what the view sends.
        let daemon: Int32

        init() throws {
            var fds: [Int32] = [0, 0]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            transport = LineTransport(connected: fds[0], path: "socketpair")
            daemon = fds[1]
            queue = TerminalEventQueue.sharedConnection()
            reader = TerminalStreamReader(transport: transport, queue: queue, control: TerminalAttachment.ControlBox(),
                                          resolvedSurface: TerminalAttachment.SurfaceBox(SurfaceID(rawValue: 4)))
            reader.stream = 9
        }

        func ready(at offset: UInt64) -> LineTransport.StreamMessage {
            let meta = Data(#"{"event":"snapshot","surface":4,"phase":"ready","generation":1,"offset":\#(offset),"version":1,"cols":80,"rows":24}"#.utf8)
            var payload = Data()
            for index in 0..<4 { payload.append(UInt8((meta.count >> (8 * index)) & 0xFF)) }
            payload += meta + Data("screen".utf8)
            return .frame(AttachFrameHeader(kind: .snapshot, stream: 9, length: payload.count, offset: offset), payload)
        }

        func output(_ text: String, at offset: UInt64) -> LineTransport.StreamMessage {
            let bytes = Data(text.utf8)
            return .frame(AttachFrameHeader(kind: .output, stream: 9, length: bytes.count, offset: offset), bytes)
        }

        /// The next `count` lines the view sent: blocks until they arrive (the
        /// transport writes on its own writer), at most 10 s.
        func sent(_ count: Int) -> [String] {
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(daemon, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var bytes: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while bytes.filter({ $0 == 0x0A }).count < count {
                let read = Darwin.read(daemon, &buffer, buffer.count)
                guard read > 0 else { break }
                bytes += buffer.prefix(read)
            }
            return String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init)
        }


        func drain() async -> [TerminalChannelEvent] {
            queue.finish()
            var events: [TerminalChannelEvent] = []
            while let event = await queue.next() { events.append(event) }
            return events
        }
    }

    @Test func aGapDropsOutputUntilTheNextReadyAndAsksForItOnTheViewsStream() async throws {
        let fixture = try Fixture()
        defer { fixture.transport.close(); close(fixture.daemon) }
        fixture.reader.receive(fixture.ready(at: 100))
        fixture.reader.receive(fixture.output("hello", at: 100))
        fixture.reader.receive(fixture.output("stale", at: 95))   // before the expected offset: a replaced screen
        fixture.reader.receive(fixture.output("lost!", at: 110))  // 105..110 never came: a gap
        fixture.reader.receive(fixture.output("after", at: 115))  // dropped while resyncing
        let sent = fixture.sent(1)
        #expect(sent.count == 1, "\(sent)")
        let request = try JSONSerialization.jsonObject(with: Data(try #require(sent.first).utf8)) as? [String: Any]
        #expect(request?["cmd"] as? String == "snapshot-request")
        #expect(request?["reason"] as? String == "gap")
        #expect(request?["attach_stream"] as? Int == 9, "the request runs on the view's own lane")
        fixture.reader.receive(fixture.ready(at: 200))
        fixture.reader.receive(fixture.output("fresh", at: 200))
        let events = await fixture.drain()
        let outputs = events.compactMap { event -> String? in
            if case .output(let data, _) = event { String(decoding: data, as: UTF8.self) } else { nil }
        }
        #expect(outputs == ["hello", "fresh"])
        let readies = events.filter { if case .snapshot(let frame) = $0 { frame.phase == .ready } else { false } }
        #expect(readies.count == 2)
    }

    /// A ring the test writes as the daemon would (cmux-tui surface/output_ring.rs),
    /// in a plain file: mapping a file descriptor is the same as a shared memory object.
    private struct TestRing {
        let path: String
        let writer: UnsafeMutableRawPointer
        let length: Int
        static let capacity = 128

        init(base: UInt64) throws {
            path = NSTemporaryDirectory() + "ring-\(UUID().uuidString)"
            var header = Data([0x43, 0x4D, 0x41, 0x52, 1, 0, 0, 0])
            for value in [UInt64(Self.capacity), base, base, base] {
                withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
            }
            header.append(Data(count: 64 - header.count + Self.capacity))
            try header.write(to: URL(fileURLWithPath: path))
            length = header.count
            let fd = open(path, O_RDWR)
            writer = try #require(mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0))
            close(fd)
        }

        /// The read-only descriptor the RING frame passes.
        func readerDescriptor() -> Int32 { open(path, O_RDONLY) }

        /// Writes `text` at offset `at` and publishes `reserve` and `end`.
        func write(_ text: String, at: UInt64, reserve: UInt64? = nil) {
            let bytes = Array(text.utf8)
            for (index, byte) in bytes.enumerated() {
                let offset = 64 + Int((at + UInt64(index)) % UInt64(Self.capacity))
                writer.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
            }
            let end = at + UInt64(bytes.count)
            writer.storeBytes(of: (reserve ?? end).littleEndian, toByteOffset: 32, as: UInt64.self)
            writer.storeBytes(of: end.littleEndian, toByteOffset: 24, as: UInt64.self)
        }

        func remove() {
            munmap(writer, length)
            unlink(path)
        }
    }

    private func advance(to end: UInt64) -> LineTransport.StreamMessage {
        .frame(AttachFrameHeader(kind: .ringAdvance, stream: 9, length: 0, offset: end), Data())
    }

    @Test func ringOutputReachesTheViewAsSpansOfTheMappingAndALapIsAGap() async throws {
        let fixture = try Fixture()
        let ring = try TestRing(base: 1000)
        defer { fixture.transport.close(); close(fixture.daemon); ring.remove() }
        let ringHeader = AttachFrameHeader(kind: .ring, stream: 9, length: 2, offset: 1000)
        fixture.reader.receive(.ring(ringHeader, Data("{}".utf8), descriptor: ring.readerDescriptor()))
        let mapping = try #require(fixture.reader.ringMapping)
        fixture.reader.receive(fixture.ready(at: 1000))
        // 1000 % 128 = 104: the 40 bytes wrap after 24. Both spans are longer
        // than Foundation's inline Data (14 bytes), which would copy them.
        let text = "spans of the mapping wrap 0123456789abcd"
        ring.write(text, at: 1000)
        fixture.reader.receive(advance(to: 1040))
        // The writer has reserved past what the reader may still read: the next
        // bytes are lost before any span of them exists (a gap, no parse).
        ring.write("xy", at: 1040, reserve: 1040 + 129)
        fixture.reader.receive(advance(to: 1042))
        let sent = fixture.sent(1)
        #expect(sent.count == 1 && sent.first?.contains("\"gap\"") == true, "\(sent)")
        var outputs: [Data] = []
        for event in await fixture.drain() {
            if case .output(let data, _) = event { outputs.append(data) }
        }
        #expect(outputs.map { String(decoding: $0, as: UTF8.self) } == [String(text.prefix(24)), String(text.dropFirst(24))],
                "two spans, split where the ring wraps")
        for output in outputs {
            output.withUnsafeBytes { raw in
                #expect(raw.baseAddress.map(mapping.contains) == true, "an output span is the mapping itself, not a copy")
            }
        }
    }

    @Test func aViewHoldingHalfTheRingResyncsInsteadOfTakingMoreSpans() async throws {
        let fixture = try Fixture()
        let ring = try TestRing(base: 0)
        defer { fixture.transport.close(); close(fixture.daemon); ring.remove() }
        let ringHeader = AttachFrameHeader(kind: .ring, stream: 9, length: 2, offset: 0)
        fixture.reader.receive(.ring(ringHeader, Data("{}".utf8), descriptor: ring.readerDescriptor()))
        fixture.reader.receive(fixture.ready(at: 0))
        // 40 bytes the view has not parsed yet: held.
        ring.write(String(repeating: "a", count: 40), at: 0)
        fixture.reader.receive(advance(to: 40))
        // 40 more would leave 80 unreleased bytes, over half the 128-byte ring.
        ring.write(String(repeating: "b", count: 40), at: 40)
        fixture.reader.receive(advance(to: 80))
        let sent = fixture.sent(1)
        #expect(sent.first?.contains("\"gap\"") == true, "\(sent)")
        var outputs: [String] = []
        for event in await fixture.drain() {
            if case .output(let data, _) = event { outputs.append(String(decoding: data, as: UTF8.self)) }
        }
        #expect(outputs == [String(repeating: "a", count: 40)], "no span past the budget was handed out")
    }

    @Test func aLoopbackEventWithAStreamFieldStillReachesTheEventHandler() async throws {
        let fixture = try Fixture()
        defer { fixture.transport.close(); close(fixture.daemon) }
        let (names, continuation) = AsyncStream.makeStream(of: String.self)
        fixture.transport.start(onEvent: { name, _, _ in continuation.yield(name) }, onClose: { _ in continuation.finish() })
        let line = Data(#"{"event":"loopback-data","stream":1,"data":"aGk="}"#.utf8) + Data([0x0A])
        _ = line.withUnsafeBytes { write(fixture.daemon, $0.baseAddress, $0.count) }
        var iterator = names.makeAsyncIterator()
        #expect(await iterator.next() == "loopback-data", "`stream` belongs to loopback-forward-v1, not to attach streams")
        #expect(fixture.transport.strayStreamMessages == 0)
    }

    @Test func anAttachThatFailsWithoutADaemonAnswerCancelsItsStreamAndARefusalDoesNot() async throws {
        let fixture = try Fixture()
        defer { fixture.transport.close(); close(fixture.daemon) }
        fixture.transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
        let identity = DaemonIdentity(capabilities: ["attach-streams-v1", "attach-frames-v1"], generation: "g")
        let carrier = TerminalStreamCarrier(transport: fixture.transport, identity: identity, frames: true)
        let target = TerminalAttachment.Target(surface: SurfaceID(rawValue: 4))
        // The daemon answers with a reply the view cannot read: no daemon refusal.
        let malformed = Task { try await TerminalAttachment.attach(carrier: carrier, target: target, size: CellSize(cols: 80, rows: 24), claimGeometry: false) }
        let attach = try #require(fixture.sent(1).first)
        let request = try #require(try JSONSerialization.jsonObject(with: Data(attach.utf8)) as? [String: Any])
        let id = try #require(request["id"] as? Int)
        let stream = try #require(request["attach_stream"] as? Int)
        let reply = Data(#"{"id":\#(id),"ok":true,"data":"not an attach reply"}"#.utf8) + Data([0x0A])
        _ = reply.withUnsafeBytes { write(fixture.daemon, $0.baseAddress, $0.count) }
        await #expect(throws: (any Error).self) { try await malformed.value }
        let cancel = try #require(fixture.sent(1).first)
        let cancelRequest = try #require(try JSONSerialization.jsonObject(with: Data(cancel.utf8)) as? [String: Any])
        #expect(cancelRequest["cmd"] as? String == "cancel-stream")
        #expect(cancelRequest["attach_stream"] as? Int == stream, "the abandoned attach's own stream ends")
        // A refusal: the daemon ends the stream itself, the view sends nothing.
        let refused = Task { try await TerminalAttachment.attach(carrier: carrier, target: target, size: CellSize(cols: 80, rows: 24), claimGeometry: false) }
        let second = try #require(fixture.sent(1).first)
        let secondID = try #require((try JSONSerialization.jsonObject(with: Data(second.utf8)) as? [String: Any])?["id"] as? Int)
        let refusal = Data(#"{"id":\#(secondID),"ok":false,"error":"surface 4 not found"}"#.utf8) + Data([0x0A])
        _ = refusal.withUnsafeBytes { write(fixture.daemon, $0.baseAddress, $0.count) }
        await #expect(throws: (any Error).self) { try await refused.value }
        var poll = pollfd(fd: fixture.daemon, events: Int16(POLLIN), revents: 0)
        #expect(poll(&poll, 1, 200) == 0, "a refused attach sends no cancel")
    }

    @Test func aStreamEndWithReasonOverflowClosesTheViewAsAnOverflow() async throws {
        let fixture = try Fixture()
        defer { fixture.transport.close(); close(fixture.daemon) }
        fixture.reader.receive(.event(name: "stream-end", line: Data(#"{"event":"stream-end","reason":"overflow"}"#.utf8)))
        #expect(await fixture.drain() == [.closed(.overflow)])
    }
}
