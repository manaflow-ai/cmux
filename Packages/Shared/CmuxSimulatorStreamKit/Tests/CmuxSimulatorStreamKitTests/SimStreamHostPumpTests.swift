import Foundation
import Testing

@testable import CmuxSimulatorStreamKit

private actor FakeFrameSource: SimStreamFrameSource {
    private var latest: SimStreamSourceFrame?

    func publish(_ frame: SimStreamSourceFrame) {
        latest = frame
    }

    func copyLatestFrame(after sequence: UInt64?) async -> SimStreamSourceFrame? {
        guard let latest else { return nil }
        if let sequence, latest.sequence <= sequence { return nil }
        return latest
    }
}

private actor CollectingSink: SimStreamMessageSending {
    private(set) var messages: [SimStreamMessage] = []

    func send(_ data: Data) async throws {
        var accumulator = SimStreamFrameAccumulator()
        accumulator.append(data)
        while let body = try accumulator.nextMessageBody() {
            messages.append(try SimStreamWireCodec.decode(body))
        }
    }

    func waitForMessages(count: Int, timeout: TimeInterval = 5) async -> [SimStreamMessage] {
        let deadline = Date().addingTimeInterval(timeout)
        while messages.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return messages
    }
}

@Suite
struct SimStreamHostPumpTests {
    private let width = 96
    private let height = 160

    private func frame(sequence: UInt64, seed: Int = 0) -> SimStreamSourceFrame {
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memset(base, Int32(truncatingIfNeeded: seed &+ Int(sequence)), bytesPerRow * height)
        }
        return SimStreamSourceFrame(
            pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow,
            sequence: sequence)
    }

    private func startRequest() -> SimStreamStartRequest {
        SimStreamStartRequest(epoch: 1, maximumLongSidePixels: 640, codecPreferences: [.h264])
    }

    private func makePump(
        sink: CollectingSink,
        onFatal: @escaping @Sendable (String) -> Void = { _ in }
    ) -> SimStreamHostPump {
        SimStreamHostPump(
            sink: sink,
            now: { Date().timeIntervalSinceReferenceDate },
            onFatal: onFatal
        )
    }

    @Test
    func configPrecedesFirstFrameAndFirstFrameIsKeyframe() async throws {
        let sink = CollectingSink()
        let source = FakeFrameSource()
        await source.publish(frame(sequence: 1))
        let pump = makePump(sink: sink)
        await pump.setSource(source, geometry: .init(displayScale: 3, orientation: .portrait))
        await pump.beginStream(
            request: startRequest(),
            geometry: .init(displayScale: 3, orientation: .portrait))

        let messages = await sink.waitForMessages(count: 2)
        guard messages.count >= 2 else {
            Issue.record("expected config + frame, got \(messages.count)")
            return
        }
        guard case .config(let config) = messages[0] else {
            Issue.record("first message was not config")
            return
        }
        #expect(config.codec == .h264)
        #expect(!config.parameterSets.isEmpty)
        guard case .frame(let first) = messages[1] else {
            Issue.record("second message was not a frame")
            return
        }
        #expect(first.flags.contains(.keyframe))
        #expect(first.sequence == 1)
        await pump.shutdown()
    }

    @Test
    func creditWindowBoundsInFlightAndNewestFrameWinsAfterAck() async throws {
        let sink = CollectingSink()
        let source = FakeFrameSource()
        await source.publish(frame(sequence: 1))
        let pump = makePump(sink: sink)
        await pump.setSource(source, geometry: .init(displayScale: 3, orientation: .portrait))
        await pump.beginStream(
            request: startRequest(),
            geometry: .init(displayScale: 3, orientation: .portrait))
        _ = await sink.waitForMessages(count: 2)

        // Publish 2..6; only one more frame (seq 2) may go out (window = 2).
        for sourceSequence in UInt64(2)...6 {
            await source.publish(frame(sequence: sourceSequence))
            await pump.signalFramePublished()
        }
        var messages = await sink.waitForMessages(count: 3)
        try? await Task.sleep(for: .milliseconds(150))
        messages = await sink.waitForMessages(count: 3)
        let framesSent = messages.compactMap { message -> SimStreamFrame? in
            guard case .frame(let value) = message else { return nil }
            return value
        }
        #expect(framesSent.count == 2, "window must cap unacked frames at 2")

        // Ack the first frame. The newest source frame (seq 6) already went
        // out as wire frame 2 (latest-wins collapsed publications 2..5), so
        // nothing may flow until a NEWER source frame exists.
        await pump.noteAck(SimStreamAck(sequence: 1, receiptMicroseconds: 0))
        try? await Task.sleep(for: .milliseconds(150))
        var frameCount = await sink.messages.filter { message in
            if case .frame = message { return true } else { return false }
        }.count
        #expect(frameCount == 2, "an ack alone must not resend an already-sent frame")

        await source.publish(frame(sequence: 7))
        await pump.signalFramePublished()
        messages = await sink.waitForMessages(count: 4)
        let afterAck = messages.compactMap { message -> SimStreamFrame? in
            guard case .frame(let value) = message else { return nil }
            return value
        }
        frameCount = afterAck.count
        #expect(frameCount == 3, "one credit + one new frame = exactly one send")
        #expect(afterAck.last?.sequence == 3)
        #expect(afterAck.last?.flags.contains(.keyframe) == false)
        await pump.shutdown()
    }

    @Test
    func keyframeRequestRedeliversCurrentFrameEvenWhenSourceIsIdle() async throws {
        let sink = CollectingSink()
        let source = FakeFrameSource()
        await source.publish(frame(sequence: 1))
        let pump = makePump(sink: sink)
        await pump.setSource(source, geometry: .init(displayScale: 3, orientation: .portrait))
        await pump.beginStream(
            request: startRequest(),
            geometry: .init(displayScale: 3, orientation: .portrait))
        _ = await sink.waitForMessages(count: 2)

        await pump.noteAck(SimStreamAck(sequence: 1, receiptMicroseconds: 0))
        await pump.requestKeyframe()
        let messages = await sink.waitForMessages(count: 3)
        let frames = messages.compactMap { message -> SimStreamFrame? in
            guard case .frame(let value) = message else { return nil }
            return value
        }
        #expect(frames.count == 2)
        #expect(frames.last?.flags.contains(.keyframe) == true)
        await pump.shutdown()
    }

    @Test
    func replacedSourceForcesKeyframeResync() async throws {
        let sink = CollectingSink()
        let source = FakeFrameSource()
        await source.publish(frame(sequence: 10))
        let pump = makePump(sink: sink)
        await pump.setSource(source, geometry: .init(displayScale: 3, orientation: .portrait))
        await pump.beginStream(
            request: startRequest(),
            geometry: .init(displayScale: 3, orientation: .portrait))
        _ = await sink.waitForMessages(count: 2)
        await pump.noteAck(SimStreamAck(sequence: 1, receiptMicroseconds: 0))

        // Worker restart: new ring, sequence space restarts at 1.
        let replacement = FakeFrameSource()
        await replacement.publish(frame(sequence: 1, seed: 99))
        await pump.setSource(
            replacement, geometry: .init(displayScale: 3, orientation: .portrait))
        let messages = await sink.waitForMessages(count: 3)
        let frames = messages.compactMap { message -> SimStreamFrame? in
            guard case .frame(let value) = message else { return nil }
            return value
        }
        #expect(frames.count == 2)
        #expect(frames.last?.flags.contains(.keyframe) == true)
        await pump.shutdown()
    }

    @Test
    func geometryChangeEmitsFreshConfigBeforeNextFrame() async throws {
        let sink = CollectingSink()
        let source = FakeFrameSource()
        await source.publish(frame(sequence: 1))
        let pump = makePump(sink: sink)
        await pump.setSource(source, geometry: .init(displayScale: 3, orientation: .portrait))
        await pump.beginStream(
            request: startRequest(),
            geometry: .init(displayScale: 3, orientation: .portrait))
        _ = await sink.waitForMessages(count: 2)
        await pump.noteAck(SimStreamAck(sequence: 1, receiptMicroseconds: 0))

        // Rotation: same source, new orientation metadata.
        await pump.setSource(source, geometry: .init(displayScale: 3, orientation: .landscapeLeft))
        await source.publish(frame(sequence: 2))
        await pump.signalFramePublished()
        let messages = await sink.waitForMessages(count: 4)
        let configs = messages.compactMap { message -> SimStreamConfig? in
            guard case .config(let value) = message else { return nil }
            return value
        }
        #expect(configs.count == 2)
        #expect(configs.last?.orientation == .landscapeLeft)
        // The frame after the new config must be a keyframe.
        if let lastConfigIndex = messages.lastIndex(where: {
            if case .config = $0 { return true } else { return false }
        }), lastConfigIndex + 1 < messages.count,
            case .frame(let after) = messages[lastConfigIndex + 1]
        {
            #expect(after.flags.contains(.keyframe))
        } else {
            Issue.record("no frame after rotated config")
        }
        await pump.shutdown()
    }

    @Test
    func repeatedEncodeFailureIsFatalNotSilent() async throws {
        let sink = CollectingSink()
        let source = FakeFrameSource()
        // Geometry lie: pixel data far too small for the declared size.
        await source.publish(
            SimStreamSourceFrame(
                pixels: Data(count: 64), width: 96, height: 160, bytesPerRow: 384, sequence: 1))
        let fatalFlag = LockedFatalFlag()
        let pump = makePump(sink: sink) { reason in fatalFlag.record(reason) }
        await pump.setSource(source, geometry: .init(displayScale: 3, orientation: .portrait))
        await pump.beginStream(
            request: startRequest(),
            geometry: .init(displayScale: 3, orientation: .portrait))

        let deadline = Date().addingTimeInterval(5)
        while fatalFlag.reason == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(fatalFlag.reason != nil)
        await pump.shutdown()
    }
}

private final class LockedFatalFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _reason: String?

    var reason: String? {
        lock.lock()
        defer { lock.unlock() }
        return _reason
    }

    func record(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        _reason = reason
    }
}
