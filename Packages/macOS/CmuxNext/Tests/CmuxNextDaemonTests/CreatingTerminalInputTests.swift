import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// Keys typed into a terminal still being created, as INPUT frames on the stream its create opened
/// (p05-ipc-153): each key is one frame of its raw bytes, in order, with no request, no reply and no wait. Once
/// the view's target is known, input goes by the attachment, after one drain of the stream when a key went on it,
/// so no key on the stream can be passed by one on the attachment. The connection is never started, so a key
/// that took the `send {terminal_id}` request path instead would fail.
struct CreatingTerminalInputTests {
    @Test func keysTypedWhileCreatingGoAsInputFramesInOrderWithNoWait() {
        let stream = RecordingKeyStream(id: 7)
        let input = creatingInput(stream: stream, targetKnown: false)
        let keys = (0..<200).map { Data("k\($0);".utf8) }
        for key in keys {
            #expect(input.writeWithoutWaiting(key) == true, "sent in the caller's turn")
        }
        let frames = stream.frames
        #expect(frames.count == keys.count)
        for (frame, key) in zip(frames, keys) {
            #expect(Array(frame.prefix(16)) == Self.header(stream: 7, length: key.count, flow: 0))
            #expect(frame.dropFirst(16) == key, "the key's raw bytes, no JSON and no base64")
        }
        #expect(stream.drains == 0)
        #expect(!input.sendsByAttachment)
    }

    @Test func onceTheTargetIsKnownInputDrainsTheStreamThenGoesByTheAttachment() async {
        let stream = RecordingKeyStream(id: 3)
        let known = TargetFlag()
        let input = creatingInput(stream: stream, targetKnown: { known.isSet })
        #expect(await input.write(Data("a".utf8)))
        known.set()
        #expect(input.writeWithoutWaiting(Data("b".utf8)) == nil, "the switch waits for the drain")
        let byStream = await input.write(Data("b".utf8))
        #expect(!byStream)
        #expect(stream.drains == 1, "the keys on the stream ran before the attachment's")
        #expect(input.sendsByAttachment)
        #expect(input.writeWithoutWaiting(Data("c".utf8)) == false)
        #expect(stream.frames.map { $0.dropFirst(16) } == [Data("a".utf8)])
        #expect(stream.drains == 1, "one drain per view")
    }

    @Test func aViewWhoseTargetIsKnownBeforeItsFirstKeyNeverDrains() {
        let stream = RecordingKeyStream(id: 4)
        let input = creatingInput(stream: stream, targetKnown: true)
        #expect(input.writeWithoutWaiting(Data("a".utf8)) == false)
        #expect(input.sendsByAttachment)
        #expect(stream.frames.isEmpty)
        #expect(stream.drains == 0)
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

    @Test func aFrameNamesItsKeyPressAndOnlyTheFirstFrameOfAChunkDoes() {
        let flow: UInt64 = 0x0102_0304_0506_0708
        let frame = CreatingTerminalInput.inputFrame(Data("x".utf8), stream: 2, flow: flow)
        #expect(Array(frame.prefix(16)) == Self.header(stream: 2, length: 1, flow: flow))
        var flows: [UInt64] = []
        var payloads: [Data] = []
        CreatingTerminalInput.forEachInputFrame(Data("abcdefg".utf8), stream: 2, flow: flow, maxPayload: 3) { frame in
            flows.append(frame.dropFirst(8).prefix(8).reversed().reduce(UInt64.zero) { $0 << 8 | UInt64($1) })
            payloads.append(Data(frame.dropFirst(16)))
            return true
        }
        #expect(payloads == [Data("abc".utf8), Data("def".utf8), Data("g".utf8)])
        #expect(flows == [flow, 0, 0])
    }

    /// INPUT (kind 9) on `stream`, `length` payload bytes, flow id `flow` (cmux-ipc frame.rs `FrameHeader`).
    private static func header(stream: UInt16, length: Int, flow: UInt64) -> [UInt8] {
        let length = UInt32(length)
        return [0xFF, 9, UInt8(stream & 0xFF), UInt8(stream >> 8),
                UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)]
            + (0..<8).map { UInt8(truncatingIfNeeded: flow >> ($0 * 8)) }
    }

    private func creatingInput(stream: RecordingKeyStream, targetKnown: Bool) -> CreatingTerminalInput {
        creatingInput(stream: stream, targetKnown: { targetKnown })
    }

    private func creatingInput(stream: RecordingKeyStream,
                               targetKnown: @escaping @Sendable () -> Bool) -> CreatingTerminalInput {
        let endpoint = DaemonEndpoint(socketPath: "/tmp/cmux-creating-input-test-\(UUID().uuidString).sock")
        let connection = DaemonConnection(endpoint: endpoint)
        return CreatingTerminalInput(terminalID: "0000000000004000800000000000153a", connection: connection,
                                     stream: stream, targetKnown: targetKnown)
    }
}

/// The view's attach target, known once ``set()`` ran.
private nonisolated final class TargetFlag: Sendable {
    // A lock: the input reads it from any task.
    private let known = Mutex(false)

    var isSet: Bool { known.withLock { $0 } }
    func set() { known.withLock { $0 = true } }
}

/// The frames a create's stream carried, in order, and its drains; it refuses every frame past `accepts`.
private nonisolated final class RecordingKeyStream: CreatingTerminalKeyStream {
    private nonisolated struct State {
        var frames: [Data] = []
        var drains = 0
    }

    let id: UInt16
    private let accepts: Int
    // A lock: the input's caller writes from any task.
    private let state = Mutex(State())

    init(id: UInt16, accepts: Int = .max) {
        self.id = id
        self.accepts = accepts
    }

    var frames: [Data] { state.withLock { $0.frames } }
    var drains: Int { state.withLock { $0.drains } }

    func sendInputFrame(_ frame: Data) -> Bool {
        state.withLock { state in
            state.frames.append(frame)
            return state.frames.count <= accepts
        }
    }

    func drain() async {
        state.withLock { $0.drains += 1 }
    }
}
