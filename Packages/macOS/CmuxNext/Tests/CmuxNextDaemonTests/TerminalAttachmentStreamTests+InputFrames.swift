import CmuxNextIPC
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A stream view's keys as INPUT frames: raw bytes behind a 16-byte header, no JSON and no
/// base64, in call order, on a stream whose `attach-surface` went as a REQUEST frame naming it, as the daemon
/// takes INPUT only on such a stream (pending_streams.rs). A view on a connection of its own, or a
/// stream whose opener went as a line, keeps `send` lines. The path is fixed at the attach reply; once the view's
/// channel ends, its keys are dropped, never sent as lines. A refused INPUT frame ends the connection.
extension TerminalAttachmentStreamTests {
    /// The peer end of one transport: a Unix socket in `/tmp` that cuts what the app writes with the same
    /// reader the daemon uses (cmux-ipc reader.rs, ported in CmuxNextIPC's ``FrameReader``) and keeps the
    /// daemon's stream rule: an opener REQUEST frame announces the stream its header names, and an INPUT frame
    /// on a stream never announced is a bad message (``UnknownStream``), on which the daemon closes.
    final class InputPeer {
        /// An INPUT frame on a stream no opener announced: the daemon's `unknown_stream` bad message.
        struct UnknownStream: Error {
            let stream: UInt16
        }

        /// The view's `attach-surface` as the peer read it.
        struct Opener {
            /// It came as a REQUEST frame (else as a JSON line).
            var framed: Bool
            /// The stream its frame header named (0 for a line).
            var headerStream: UInt16
            /// The `stream` of its body.
            var bodyStream: UInt16?
        }

        let path = "/tmp/cnd-inpt-\(UUID().uuidString.prefix(8).lowercased()).sock"
        private let listener: Int32
        private var peer: Int32 = -1
        private var reader = FrameReader()
        /// The streams an opener's header announced.
        private(set) var announced: Set<UInt16> = []

        init() throws {
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
                buffer[bytes.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
            reader.negotiateFrames()
        }

        deinit {
            if peer >= 0 { close(peer) }
            close(listener)
            unlink(path)
        }

        /// A started transport connected to this peer, holding `grants` and framing requests with `framing`, as
        /// a handshake that negotiated them leaves it.
        func transport(grants: DaemonWireGrants, framing: FramedRequests? = nil,
                       writerLimit: Int = FrameWriter.defaultLimit) throws -> LineTransport {
            let transport = try LineTransport(path: path, role: .control, stats: nil, writerLimit: writerLimit)
            peer = Darwin.accept(listener, nil, nil)
            guard peer >= 0 else { throw POSIXError(.ECONNABORTED) }
            if grants.frames { transport.acceptFrames() }
            transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
            transport.adopt(WireNegotiation.Granted(grants: grants, framing: framing))
            return transport
        }

        /// Reads the view's `attach-surface` and answers it the way it came: a REPLY frame on the stream its
        /// header named, or a reply line. With `failing`, a framed open fails after the daemon took the stream:
        /// `stream-end {attach_failed}`, then the ERROR frame (pending_streams.rs, `open_failed`).
        func answerOpener(failing: Bool = false) throws -> Opener {
            let message = try #require(try messages(1).first)
            switch message {
            case .frame(let frame):
                #expect(frame.header.kind == FramedRequests.requestKind)
                let stream = frame.header.stream
                announced.insert(stream)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any])
                #expect(body["cmd"] as? String == AttachSurfaceRequest.command)
                let id = try #require(body["id"] as? Int)
                if failing { try send(line: ["stream": Int(stream), "event": "stream-end", "reason": "attach_failed"]) }
                let reply: [String: Any] = failing
                    ? ["id": id, "ok": false, "error": "no such surface", "error_code": "not_found"]
                    : ["id": id, "ok": true, "data": ["lease": "lease-\(id)"]]
                let payload = try JSONSerialization.data(withJSONObject: reply)
                // The request's header with the reply's kind and length: same stream and call fields.
                var out = Data(frame.header.encode())
                out[1] = failing ? FramedRequests.errorKind : FramedRequests.replyKind
                for index in 0..<4 { out[4 + index] = UInt8(truncatingIfNeeded: payload.count >> (8 * index)) }
                out.append(payload)
                try write(out)
                return Opener(framed: true, headerStream: stream,
                              bodyStream: (body["stream"] as? Int).flatMap { UInt16(exactly: $0) })
            case .json(let bytes):
                let body = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
                #expect(body["cmd"] as? String == AttachSurfaceRequest.command)
                let id = try #require(body["id"] as? Int)
                try send(line: ["id": id, "ok": true, "data": ["lease": "lease-\(id)"]])
                return Opener(framed: false, headerStream: 0,
                              bodyStream: (body["stream"] as? Int).flatMap { UInt16(exactly: $0) })
            }
        }

        /// The next `count` messages the app wrote, cut as the daemon cuts them. Throws ``UnknownStream`` at an
        /// INPUT frame on a stream no opener announced, and `ECONNRESET` at EOF.
        func messages(_ count: Int) throws -> [FrameReader.Message] {
            var messages: [FrameReader.Message] = []
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            while messages.count < count {
                while messages.count < count, let message = try reader.next() {
                    if case .frame(let frame) = message, frame.header.kind == TerminalAttachment.inputFrameKind,
                       !announced.contains(frame.header.stream) {
                        throw UnknownStream(stream: frame.header.stream)
                    }
                    messages.append(message)
                }
                guard messages.count < count else { break }
                let received = chunk.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
                guard received > 0 else { throw POSIXError(.ECONNRESET) }
                chunk.withUnsafeBytes { reader.push(UnsafeRawBufferPointer(rebasing: $0.prefix(received))) }
            }
            return messages
        }

        /// Writes `bytes` of live output on `stream` in 64 KiB chunks, tagged as the daemon tags a stream's items.
        func sendOutput(stream: UInt16, surface: SurfaceID, bytes: Int) throws {
            let chunk = 64 << 10
            var sent = 0
            while sent < bytes {
                let size = min(chunk, bytes - sent)
                try send(line: ["stream": Int(stream), "event": "output", "surface": Int(surface.rawValue),
                                "data": Data(repeating: UInt8(ascii: "o"), count: size).base64EncodedString()])
                sent += size
            }
        }

        /// Answers the request line `message` with `ok` and `data`.
        func reply(to message: FrameReader.Message, data: [String: Any]) throws {
            guard case .json(let bytes) = message else { throw POSIXError(.EBADMSG) }
            let body = try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
            try send(line: ["id": try #require(body["id"] as? Int), "ok": true, "data": data])
        }

        /// Reads up to the request line `cmd`, answers it with `ok` and `data`, and returns what came before it.
        func answer(_ cmd: String, data: [String: Any]) throws -> [FrameReader.Message] {
            var before: [FrameReader.Message] = []
            while true {
                let message = try #require(try messages(1).first)
                if case .json(let bytes) = message,
                   let body = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                   body["cmd"] as? String == cmd {
                    try reply(to: message, data: data)
                    return before
                }
                before.append(message)
            }
        }

        func send(line object: [String: Any]) throws {
            var line = try JSONSerialization.data(withJSONObject: object)
            line.append(0x0A)
            try write(line)
        }

        private func write(_ data: Data) throws {
            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { raw in
                    Darwin.write(peer, raw.baseAddress.map { $0 + offset }, raw.count - offset)
                }
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw POSIXError(.EPIPE) }
                offset += written
            }
        }
    }

    private static let viewSurface = SurfaceID(rawValue: 5)
    private static let viewSize = CellSize(cols: 80, rows: 24)

    /// A daemon that answers `attach-surface` on frames: the only method this table frames.
    private static let framing: FramedRequests = {
        let attach = MethodAttributes(id: MethodID(rawValue: 0x0100), name: AttachSurfaceRequest.command,
                                      priority: .control, ordering: .sequence, durability: .readOnly, payload: .json,
                                      streamScoped: false, crossesStreamOK: nil, maxBytes: nil, coalesce: nil,
                                      urgent: false)
        let table = MethodTable(v12: [MethodTableFamily(id: 0x01, name: "terminal-io-test", entries: [attach])],
                                v2: [], events: [])
        return FramedRequests(table: table, served: [attach.id])
    }()

    /// A view of `viewSurface` attached as a stream of `transport` (``TerminalAttachment/attachStream``), its
    /// opener answered by `peer`.
    private static func streamView(on transport: LineTransport, peer: InputPeer,
                                   failing: Bool = false) async throws -> (TerminalAttachment, InputPeer.Opener) {
        let carrier = TerminalStreamCarrier(
            transport: transport,
            identity: DaemonIdentity(capabilities: [TerminalAttachment.streamsCapability],
                                     generation: DaemonGeneration(rawValue: "input-frames")))
        let (target, size) = (TerminalAttachment.Target(surface: Self.viewSurface), Self.viewSize)
        let attaching = Task {
            try await TerminalAttachment.attachStream(on: carrier, target: target, size: size,
                                                      claimGeometry: false, snapshotVersion: nil, localHistory: false,
                                                      images: false, createIntent: 0)
        }
        let opener: InputPeer.Opener
        do {
            opener = try peer.answerOpener(failing: failing)
        } catch {
            attaching.cancel()
            throw error
        }
        return (try await attaching.value, opener)
    }

    /// The flow id of an INPUT frame (aux bytes 8-15, little endian).
    private static func flow(of frame: Frame) -> UInt64 {
        frame.header.encode()[8..<16].reversed().reduce(UInt64.zero) { $0 << 8 | UInt64($1) }
    }

    private static func json(_ message: FrameReader.Message) throws -> [String: Any] {
        guard case .json(let bytes) = message else {
            Issue.record("expected a JSON line, got \(message)")
            return [:]
        }
        return try #require(try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
    }

    private static func endReason(of view: TerminalAttachment) async -> TerminalChannelCloseReason? {
        for await event in view.events {
            if case .closed(let reason) = event { return reason }
        }
        return nil
    }

    /// Red before the opener was framed on its stream (it went on stream 0, so the daemon took the first key as
    /// `unknown_stream` and closed the connection): with frames and streams granted, the view's `attach-surface`
    /// goes as a REQUEST frame whose header names the view's stream, and 10,000 keys typed on a non-main
    /// thread, as Ghostty's `io_write_cb` thread types them, follow as one INPUT frame each on that announced
    /// stream, in order, with the bytes unchanged. The reader cuts exactly those 10,000 frames and nothing else,
    /// so no key was encoded as JSON or base64, and the connection stays open.
    @Test func tenThousandKeysGoAsInputFramesOnTheAnnouncedStream() async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true), framing: Self.framing)
        defer { transport.close() }
        let (view, opener) = try await Self.streamView(on: transport, peer: peer)
        let stream = try #require(view.stream?.id)
        #expect(opener.framed)
        #expect(opener.headerStream == stream)
        #expect(opener.bodyStream == stream)
        let keys = (0..<10_000).map { Data("k\($0);".utf8) }
        let typist = Thread { for key in keys { view.enqueueInput(key) } }
        typist.name = "TerminalAttachmentStreamTests.io_write"
        typist.start()

        let messages = try peer.messages(keys.count)
        var frames: [Frame] = []
        for message in messages {
            guard case .frame(let frame) = message else {
                Issue.record("a key left as a line: \(message)")
                return
            }
            frames.append(frame)
        }
        #expect(frames.allSatisfy { $0.header.kind == TerminalAttachment.inputFrameKind })
        #expect(frames.allSatisfy { $0.header.stream == stream })
        #expect(frames.allSatisfy { Self.flow(of: $0) == 0 }, "no press is open while the typing probe is off")
        #expect(frames.map { Data($0.payload) } == keys)
        #expect(!transport.isClosed)
    }

    /// A view on a connection of its own has no stream: INPUT on stream 0 is a bad message, so its keys stay
    /// `send` lines even where frames are granted.
    @Test func aViewOnItsOwnConnectionSendsLines() throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: false), framing: Self.framing)
        defer { transport.close() }
        let view = TerminalAttachment(transport: transport, surface: Self.viewSurface)
        view.enqueueInput(Data("a".utf8))
        let line = try Self.json(try #require(try peer.messages(1).first))
        #expect(line["cmd"] as? String == SendInputRequest.command)
        #expect(line["surface"] as? Int == Int(Self.viewSurface.rawValue))
        #expect(line["bytes"] as? String == Data("a".utf8).base64EncodedString())
    }

    /// A stream whose opener went as a line announced nothing to the daemon, so its keys are `send` lines: with
    /// frames granted by a daemon that does not answer `attach-surface` on frames, and with no frames granted
    /// (a bridge, another API revision).
    @Test(arguments: [true, false]) func aStreamOpenedByALineSendsLines(framesGranted: Bool) async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: framesGranted, streams: true))
        defer { transport.close() }
        let (view, opener) = try await Self.streamView(on: transport, peer: peer)
        #expect(!opener.framed)
        view.enqueueInput(Data("b".utf8))
        let line = try Self.json(try #require(try peer.messages(1).first))
        #expect(line["cmd"] as? String == SendInputRequest.command)
        #expect(line["bytes"] as? String == Data("b".utf8).base64EncodedString())
    }

    /// An opener that fails after the daemon took its stream: `stream-end` frees the id, then its ERROR frame
    /// comes on that stream. The reader routes it to the attach, which fails, and the connection stays open.
    @Test func aFailedFramedOpenerKeepsTheConnection() async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true), framing: Self.framing)
        defer { transport.close() }
        await #expect(throws: DaemonError.self) {
            _ = try await Self.streamView(on: transport, peer: peer, failing: true)
        }
        #expect(!transport.isClosed)
        #expect(transport.attachStreamCount == 0)
    }

    /// Once the view detached, its stream may already be gone on the daemon: a key typed after it is dropped,
    /// never written as INPUT behind the `cancel-stream`. The marker line written last is the next message, so
    /// no frame was written in between (an INPUT frame would have gone ahead of it, at input priority).
    @Test func aDetachedStreamViewWritesNoInput() async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true), framing: Self.framing)
        defer { transport.close() }
        let (view, _) = try await Self.streamView(on: transport, peer: peer)
        let stream = try #require(view.stream?.id)
        view.detachNow()
        view.enqueueInput(Data("late".utf8))
        #expect(transport.sendLine(Data(#"{"marker":true}"#.utf8)))
        let messages = try peer.messages(2)
        let cancel = try Self.json(messages[0])
        #expect(cancel["cmd"] as? String == CancelStreamRequest.command)
        #expect(cancel["stream"] as? Int == Int(stream))
        #expect(try Self.json(messages[1])["marker"] as? Bool == true)
    }

    /// Red while the path was chosen per key: a cancelled stream still counted as announced (its keys went as
    /// INPUT, which the daemon drops on an ended stream) and a released one fell back to `send` lines, which
    /// reach the PTY. A view that overflows closes its input with its channel: the key typed before the overflow
    /// went as INPUT, and keys typed between the `cancel-stream` and its reply, or after the id is free, reach
    /// the peer in no form. So no `send` line follows an INPUT the daemon may have dropped.
    @Test func keysAfterAnOverflowAreDroppedNeverSentAsLines() async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true), framing: Self.framing)
        defer { transport.close() }
        let (view, opener) = try await Self.streamView(on: transport, peer: peer)
        #expect(opener.framed)
        let stream = opener.headerStream
        view.enqueueInput(Data("a".utf8))
        // Past the view queue's 8 MiB high water, with nobody reading the view.
        try peer.sendOutput(stream: stream, surface: Self.viewSurface, bytes: 9 << 20)
        let early = try peer.messages(2)
        #expect(Self.inputPayload(early[0]) == Data("a".utf8))
        let cancel = try Self.json(early[1])
        #expect(cancel["cmd"] as? String == CancelStreamRequest.command)
        #expect(cancel["stream"] as? Int == Int(stream))

        view.enqueueInput(Data("b".utf8))
        try peer.reply(to: early[1], data: ["stream": Int(stream), "outcome": "applied"])
        // One round trip behind that reply: once it returns, the reader has released the id.
        async let probe = DaemonConnection.perform(CancelStreamRequest(stream: 999), on: transport)
        let strays = try peer.answer(CancelStreamRequest.command, data: ["stream": 999, "outcome": "ended"])
        _ = try await probe
        #expect(strays.isEmpty, "a key typed after the overflow reached the peer: \(strays)")
        #expect(transport.attachStreamCount == 0)

        view.enqueueInput(Data("c".utf8))
        #expect(transport.sendLine(Data(#"{"marker":true}"#.utf8)))
        #expect(try Self.json(try #require(try peer.messages(1).first))["marker"] as? Bool == true)
        #expect(await Self.endReason(of: view) == .overflow)
    }

    /// Red while the daemon's `stream-end` cleared the announcement (the next key went as a `send` line, behind
    /// INPUT frames the daemon dropped on the ended stream): the key before the end went as INPUT, and a key
    /// after the view saw its end reaches the peer in no form.
    @Test func keysAfterTheDaemonEndsTheStreamAreDroppedNeverSentAsLines() async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true), framing: Self.framing)
        defer { transport.close() }
        let (view, opener) = try await Self.streamView(on: transport, peer: peer)
        #expect(opener.framed)
        let stream = opener.headerStream
        view.enqueueInput(Data("a".utf8))
        #expect(Self.inputPayload(try #require(try peer.messages(1).first)) == Data("a".utf8))
        try peer.send(line: ["stream": Int(stream), "event": "stream-end", "reason": "detached"])
        #expect(await Self.endReason(of: view) == .surfaceGone)
        #expect(transport.attachStreamCount == 0)

        view.enqueueInput(Data("b".utf8))
        #expect(transport.sendLine(Data(#"{"marker":true}"#.utf8)))
        #expect(try Self.json(try #require(try peer.messages(1).first))["marker"] as? Bool == true)
    }

    /// A cancelled stream is ending on the daemon, so it no longer counts as announced.
    @Test func aCancelledStreamIsNotAnnounced() throws {
        var table = AttachStreamTable()
        // Reserve outside #require: the macro wraps its argument in a closure, which cannot call a mutating method.
        let reserved = table.reserve()
        let handle = try #require(reserved)
        let bound = table.bind(handle, AttachStreamSink(dispatch: .control) { _ in })
        #expect(bound)
        table.announce(handle)
        #expect(table.isAnnounced(handle))
        let cancelled = table.cancel(handle)
        #expect(cancelled)
        #expect(!table.isAnnounced(handle))
    }

    /// The payload of an INPUT frame; nil for any other message.
    private static func inputPayload(_ message: FrameReader.Message) -> Data? {
        guard case .frame(let frame) = message, frame.header.kind == TerminalAttachment.inputFrameKind else { return nil }
        return Data(frame.payload)
    }

    /// Red while a refusal was only logged (the next key went out behind the missing one): an INPUT frame the
    /// writer refuses, here one past its backlog limit, ends the connection. The view sees its stream lost, so
    /// it reattaches, and no later key reaches the peer.
    @Test func aRefusedInputFrameEndsTheConnection() async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true), framing: Self.framing,
                                           writerLimit: 4096)
        defer { transport.close() }
        let (view, opener) = try await Self.streamView(on: transport, peer: peer)
        #expect(opener.framed)
        view.enqueueInput(Data(repeating: UInt8(ascii: "p"), count: 8192))
        #expect(transport.isClosed)
        view.enqueueInput(Data("after".utf8))
        guard case .connectionLost? = await Self.endReason(of: view) else {
            Issue.record("the view's stream did not end as lost")
            return
        }
        #expect(throws: POSIXError.self) { _ = try peer.messages(1) }
    }

    /// The header layout equals the cross-language golden vector (cmux-tui/spec/fixtures/ipc-frames/input.bin).
    @Test func anInputFrameMatchesTheGoldenVector() throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("cmux-tui/spec").path) {
            let parent = root.deletingLastPathComponent()
            try #require(parent.path != root.path, "no cmux-tui/spec above \(#filePath)")
            root = parent
        }
        let golden = try Data(contentsOf: root.appendingPathComponent("cmux-tui/spec/fixtures/ipc-frames/input.bin"))
        let frame = TerminalAttachment.inputFrame(Data("input-payload\nwith a newline".utf8), stream: 3,
                                                  flow: 0x2345_6789_ABCD_EF01)
        #expect(frame == golden)
    }

    /// A write past one frame's payload goes in several frames, in order; only the first names the press.
    @Test func aLongWriteIsCutIntoFramesAndOnlyTheFirstNamesThePress() throws {
        let data = Data((0..<10).map { UInt8($0) })
        var frames: [Data] = []
        TerminalAttachment.forEachInputFrame(data, stream: 7, flow: 9, maxPayload: 4) { frames.append($0); return true }
        var reader = FrameReader()
        reader.negotiateFrames()
        for frame in frames { frame.withUnsafeBytes { reader.push($0) } }
        var cut: [Frame] = []
        while case .frame(let frame)? = try reader.next() { cut.append(frame) }
        #expect(cut.map(\.payload) == [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9]])
        #expect(cut.map(\.header.stream) == [7, 7, 7])
        #expect(cut.map(Self.flow(of:)) == [9, 0, 0])

        var sent = 0
        TerminalAttachment.forEachInputFrame(data, stream: 7, flow: nil, maxPayload: 4) { _ in sent += 1; return false }
        #expect(sent == 1, "a refused frame stops the rest")
    }
}
