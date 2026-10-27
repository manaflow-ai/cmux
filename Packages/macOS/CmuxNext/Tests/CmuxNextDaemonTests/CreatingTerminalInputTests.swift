import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Keys typed into a terminal still being created, as INPUT frames on the stream its create opened
/// (p05-ipc-153): each key is one frame of its raw bytes, in order, with no request and no reply, and the keys
/// stay on that stream once the view's target is known. The connection is never started, so a key that took
/// the `send {terminal_id}` request path instead would fail.
struct CreatingTerminalInputTests {
    @Test func keysTypedWhileCreatingGoAsInputFramesInOrderWithNoRequest() async {
        let stream = RecordingKeyStream(id: 7)
        let input = creatingInput(stream: stream, targetKnown: false)
        let keys = (0..<200).map { Data("k\($0);".utf8) }
        for key in keys {
            #expect(await input.write(key))
        }
        let frames = stream.frames
        #expect(frames.count == keys.count)
        for (frame, key) in zip(frames, keys) {
            #expect(Array(frame.prefix(16)) == Self.header(stream: 7, length: key.count))
            #expect(frame.dropFirst(16) == key, "the key's raw bytes, no JSON and no base64")
        }
        #expect(!input.sendsByAttachment)
    }

    @Test func keysStayOnTheStreamOnceTheTargetIsKnown() async {
        let stream = RecordingKeyStream(id: 3)
        let input = creatingInput(stream: stream, targetKnown: true)
        #expect(await input.write(Data("a".utf8)))
        #expect(await input.write(Data("b".utf8)))
        #expect(stream.frames.map { $0.dropFirst(16) } == [Data("a".utf8), Data("b".utf8)])
        #expect(!input.sendsByAttachment)
    }

    @Test func aRefusedFrameSendsTheRestByTheAttachment() async {
        let stream = RecordingKeyStream(id: 5, accepts: 1)
        let input = creatingInput(stream: stream, targetKnown: false)
        #expect(await input.write(Data("sent".utf8)))
        let refused = await input.write(Data("refused".utf8))
        #expect(!refused)
        #expect(input.sendsByAttachment)
        let later = await input.write(Data("later".utf8))
        #expect(!later)
        #expect(stream.frames.count == 2, "nothing is written after the refusal")
    }

    @Test func aChunkLargerThanOneFrameIsCutInOrder() {
        var payloads: [Data] = []
        CreatingTerminalInput.forEachInputFrame(Data("abcdefg".utf8), stream: 2, maxPayload: 3) { frame in
            payloads.append(Data(frame.dropFirst(16)))
            return true
        }
        #expect(payloads == [Data("abc".utf8), Data("def".utf8), Data("g".utf8)])
    }

    /// INPUT (kind 9) on `stream`, `length` payload bytes, flow id 0 (cmux-ipc frame.rs `FrameHeader`).
    private static func header(stream: UInt16, length: Int) -> [UInt8] {
        let length = UInt32(length)
        return [0xFF, 9, UInt8(stream & 0xFF), UInt8(stream >> 8),
                UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)]
            + [UInt8](repeating: 0, count: 8)
    }

    private func creatingInput(stream: RecordingKeyStream, targetKnown: Bool) -> CreatingTerminalInput {
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-creating-input-test-\(UUID().uuidString).sock")
        let connection = DaemonConnection(endpoint: endpoint)
        return CreatingTerminalInput(terminalID: "0000000000004000800000000000153a", connection: connection,
                                     stream: stream, targetKnown: { targetKnown })
    }
}

/// The frames a create's stream carried, in order; it refuses every frame past `accepts`.
private nonisolated final class RecordingKeyStream: CreatingTerminalKeyStream {
    let id: UInt16
    private let accepts: Int
    // A lock: the input's caller writes from any task.
    private let written = Mutex([Data]())

    init(id: UInt16, accepts: Int = .max) {
        self.id = id
        self.accepts = accepts
    }

    var frames: [Data] { written.withLock { $0 } }

    func sendInputFrame(_ frame: Data) -> Bool {
        written.withLock { frames in
            frames.append(frame)
            return frames.count <= accepts
        }
    }
}
