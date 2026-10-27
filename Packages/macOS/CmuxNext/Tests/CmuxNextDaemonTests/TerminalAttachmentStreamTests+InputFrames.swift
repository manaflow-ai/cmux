import CmuxNextIPC
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A stream view's keys as INPUT frames (p05-ipc-096): raw bytes behind a 16-byte header, no JSON and no
/// base64, in call order; a view on a connection of its own, or one the daemon granted no frames, keeps
/// `send` lines.
extension TerminalAttachmentStreamTests {
    /// The peer end of one transport: a Unix socket in `/tmp` that cuts what the app writes with the same
    /// reader the daemon uses (cmux-ipc reader.rs, ported in CmuxNextIPC's ``FrameReader``).
    final class InputPeer {
        let path = "/tmp/cnd-inpt-\(UUID().uuidString.prefix(8).lowercased()).sock"
        private let listener: Int32
        private var peer: Int32 = -1
        private var reader = FrameReader()

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

        /// A started transport connected to this peer, holding `grants`.
        func transport(grants: DaemonWireGrants) throws -> LineTransport {
            let transport = try LineTransport(path: path, role: .control, stats: nil)
            peer = Darwin.accept(listener, nil, nil)
            guard peer >= 0 else { throw POSIXError(.ECONNABORTED) }
            transport.start(onEvent: { _, _, _ in }, onClose: { _ in })
            transport.adopt(WireNegotiation.Granted(grants: grants, framing: nil))
            return transport
        }

        /// The next `count` messages the app wrote, cut as the daemon cuts them.
        func messages(_ count: Int) throws -> [FrameReader.Message] {
            var messages: [FrameReader.Message] = []
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            while messages.count < count {
                while messages.count < count, let message = try reader.next() { messages.append(message) }
                guard messages.count < count else { break }
                let received = chunk.withUnsafeMutableBytes { Darwin.read(peer, $0.baseAddress, $0.count) }
                guard received > 0 else { throw POSIXError(.ECONNRESET) }
                chunk.withUnsafeBytes { reader.push(UnsafeRawBufferPointer(rebasing: $0.prefix(received))) }
            }
            return messages
        }
    }

    private static let viewSurface = SurfaceID(rawValue: 5)

    /// A view of `viewSurface` on its own stream of `transport`.
    private static func streamView(on transport: LineTransport) throws -> (TerminalAttachment, AttachStreamHandle) {
        let handle = try transport.reserveAttachStream()
        #expect(transport.bindAttachStream(handle) { _ in })
        return (TerminalAttachment(transport: transport, surface: viewSurface, stream: handle), handle)
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

    /// 10,000 keys typed on a non-main thread, as Ghostty's `io_write_cb` thread types them: one INPUT frame
    /// each on the view's stream, in order, with the bytes unchanged. The reader cuts exactly those 10,000
    /// frames and nothing else, so no key was encoded as JSON or base64.
    @Test func tenThousandKeysGoAsInputFramesInOrder() async throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true))
        defer { transport.close() }
        let (view, handle) = try Self.streamView(on: transport)
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
        #expect(frames.allSatisfy { $0.header.stream == handle.id })
        #expect(frames.allSatisfy { Self.flow(of: $0) == 0 }, "no press is open while the typing probe is off")
        #expect(frames.map { Data($0.payload) } == keys)
    }

    /// A view on a connection of its own has no stream: INPUT on stream 0 is a bad message, so its keys stay
    /// `send` lines even where frames are granted.
    @Test func aViewOnItsOwnConnectionSendsLines() throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: false))
        defer { transport.close() }
        let view = TerminalAttachment(transport: transport, surface: Self.viewSurface)
        view.enqueueInput(Data("a".utf8))
        let line = try Self.json(try #require(try peer.messages(1).first))
        #expect(line["cmd"] as? String == SendInputRequest.command)
        #expect(line["surface"] as? Int == Int(Self.viewSurface.rawValue))
        #expect(line["bytes"] as? String == Data("a".utf8).base64EncodedString())
    }

    /// A stream on a connection the daemon granted no frames (a bridge, another API revision): `send` lines.
    @Test func aStreamWithoutTheFramesGrantSendsLines() throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: false, streams: true))
        defer { transport.close() }
        let (view, _) = try Self.streamView(on: transport)
        view.enqueueInput(Data("b".utf8))
        let line = try Self.json(try #require(try peer.messages(1).first))
        #expect(line["cmd"] as? String == SendInputRequest.command)
        #expect(line["bytes"] as? String == Data("b".utf8).base64EncodedString())
    }

    /// Once the view detached, its stream may already be gone on the daemon: a key typed after it is dropped,
    /// never written as INPUT behind the `cancel-stream`. The marker line written last is the next message, so
    /// no frame was written in between (an INPUT frame would have gone ahead of it, at input priority).
    @Test func aDetachedStreamViewWritesNoInput() throws {
        let peer = try InputPeer()
        let transport = try peer.transport(grants: DaemonWireGrants(frames: true, streams: true))
        defer { transport.close() }
        let (view, handle) = try Self.streamView(on: transport)
        view.detachNow()
        view.enqueueInput(Data("late".utf8))
        #expect(transport.sendLine(Data(#"{"marker":true}"#.utf8)))
        let messages = try peer.messages(2)
        let cancel = try Self.json(messages[0])
        #expect(cancel["cmd"] as? String == CancelStreamRequest.command)
        #expect(cancel["stream"] as? Int == Int(handle.id))
        #expect(try Self.json(messages[1])["marker"] as? Bool == true)
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
