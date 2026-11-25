@testable import CmuxNextRemoteView
import CoreGraphics
import Foundation
import Testing

/// Leo, 2026-11-17: "but where's the speed? we were in the process of improving these".
///
/// A cmux.rd/1 host numbers a frame before it encodes it; when the encoder drops that frame
/// (design D3: not a loss) the next frame skips a number but still predicts from the last frame
/// sent. The viewer read the skipped number as a loss: it hid every later frame and asked for an
/// IDR, so the picture froze until a keyframe came back (the host limits IDRs to one per 250 ms,
/// and an IDR is the largest frame there is). It now follows the frame's named reference.
@Suite struct RemoteEncoderDropTests {
    private static let frames = 30
    private static let droppedNumber: UInt32 = 6

    /// One second-half of a 60 fps stream, encoded for real, numbered as a host whose encoder
    /// dropped frame 6: 1 to 5, then 7 on, each naming the frame before it as its reference.
    private static func stream(namingReferences: Bool) throws -> [RemoteAccessUnit] {
        let encoder = try #require(SyntheticFrameEncoder(codec: .h264, width: 320, height: 240))
        let collected = Collected()
        for index in 0..<frames {
            let buffer = try #require(encoder.makeBuffer())
            SyntheticFramePainter.paint(.init(counter: UInt16(index), pointer: CGPoint(x: 10 + index * 4, y: 40)), into: buffer)
            encoder.encode(buffer, index: index, forceKeyframe: index == 0) { output in collected.append(output) }
            encoder.flush()
        }
        let outputs = collected.all
        try #require(outputs.count == frames)
        var units: [RemoteAccessUnit] = []
        var number: UInt32 = 0
        for output in outputs {
            let previous = number
            number += 1
            if number == droppedNumber { number += 1 }
            units.append(RemoteAccessUnit(
                frame: number, flags: output.keyframe ? .keyframe : [], tCaptureMicros: UInt64(number) * 16_667,
                data: output.data, codec: .h264,
                refFrame: namingReferences && !output.keyframe ? previous : nil))
        }
        return units
    }

    private static func run(_ units: [RemoteAccessUnit]) async -> (shown: Int, keyframeRequests: Int) {
        let source = CountingSource()
        let shown = Counter()
        let pipeline = RemoteDecodePipeline(source: source, deliver: { _ in shown.add() })
        for unit in units { await pipeline.decode(unit) }
        return (shown.value, source.keyframeRequests)
    }

    @Test func anEncoderDropDoesNotFreezeThePicture() async throws {
        // Before: the viewer had no reference to read, so it fell back to frame numbers.
        let before = await Self.run(try Self.stream(namingReferences: false))
        let after = await Self.run(try Self.stream(namingReferences: true))
        let interval = 1000.0 / 60
        let frozenBefore = Double(Self.frames - before.shown) * interval
        let frozenAfter = Double(Self.frames - after.shown) * interval
        print("rd-encoder-drop: \(Self.frames) frames at 60 fps, the host's encoder dropped frame \(Self.droppedNumber):"
            + " before \(before.shown) shown, \(before.keyframeRequests) IDR asked, picture frozen \(String(format: "%.0f", frozenBefore)) ms and on until an IDR arrives;"
            + " after \(after.shown) shown, \(after.keyframeRequests) IDR asked, frozen \(String(format: "%.0f", frozenAfter)) ms")
        #expect(before.shown == 5 && before.keyframeRequests == 1, "the number fallback still treats a gap as a loss")
        #expect(after.shown == Self.frames)
        #expect(after.keyframeRequests == 0)
    }

    @Test func aFrameThatPredictsFromALostFrameIsStillHidden() async throws {
        // A frame the transport lost (not one the encoder dropped): 7 names 6, which never came.
        var units = try Self.stream(namingReferences: true)
        let lost = try #require(units.firstIndex { $0.frame == 7 })
        units[lost].refFrame = Self.droppedNumber
        let result = await Self.run(units)
        #expect(result.shown == 5)
        #expect(result.keyframeRequests == 1)
    }

    @Test func theChainRule() {
        func unit(_ frame: UInt32, ref: UInt32?) -> RemoteAccessUnit {
            RemoteAccessUnit(frame: frame, flags: [], tCaptureMicros: 0, data: Data(), codec: .h264, refFrame: ref)
        }
        #expect(RemoteDecodePipeline.continues(unit(7, ref: 5), after: 5))
        #expect(!RemoteDecodePipeline.continues(unit(7, ref: 6), after: 5))
        #expect(RemoteDecodePipeline.continues(unit(6, ref: nil), after: 5))
        #expect(!RemoteDecodePipeline.continues(unit(7, ref: nil), after: 5))
    }
}

private nonisolated final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [(data: Data, keyframe: Bool)] = []
    func append(_ output: (data: Data, keyframe: Bool)?) {
        guard let output else { return }
        lock.withLock { outputs.append(output) }
    }
    var all: [(data: Data, keyframe: Bool)] { lock.withLock { outputs } }
}

private nonisolated final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private nonisolated final class CountingSource: RemoteViewStreamSource, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var keyframeRequests: Int { lock.withLock { requests } }
    func accessUnits() -> AsyncStream<RemoteAccessUnit> { AsyncStream { $0.finish() } }
    func statusUpdates() -> AsyncStream<RemoteViewStatus> { AsyncStream { $0.finish() } }
    func cursorUpdates() -> AsyncStream<RemoteCursorState> { AsyncStream { $0.finish() } }
    func requestKeyframe() { lock.withLock { requests += 1 } }
}
