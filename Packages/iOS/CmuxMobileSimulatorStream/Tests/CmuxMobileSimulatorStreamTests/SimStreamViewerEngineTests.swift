import CmuxMobileRPC
import CmuxSimulatorStreamKit
import CoreMedia
import Foundation
import Testing

@testable import CmuxMobileSimulatorStream

/// Scripted host side of a lane: hands the engine queued inbound chunks and
/// records everything the engine sends.
private actor FakeLane: MobileSimulatorStreamLaneConnection {
    private var inbound: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private(set) var sent: [SimStreamMessage] = []
    private var finished = false
    private var sendError: Error?

    func hostSends(_ message: SimStreamMessage) {
        push(SimStreamWireCodec.encodeFramed(message))
    }

    func hostFinishes() {
        finished = true
        while !waiters.isEmpty {
            waiters.removeFirst().resume(returning: nil)
        }
    }

    func failSends(_ error: Error) {
        sendError = error
    }

    private func push(_ data: Data) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: data)
        } else {
            inbound.append(data)
        }
    }

    func receive() async throws -> Data? {
        if !inbound.isEmpty { return inbound.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func send(_ data: Data) async throws {
        if let sendError { throw sendError }
        var accumulator = SimStreamFrameAccumulator()
        accumulator.append(data)
        while let body = try accumulator.nextMessageBody() {
            sent.append(try SimStreamWireCodec.decode(body))
        }
    }

    func close() async {
        hostFinishes()
    }

    func waitForSent(count: Int, timeout: TimeInterval = 5) async -> [SimStreamMessage] {
        let deadline = Date().addingTimeInterval(timeout)
        while sent.count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sent
    }

    /// Batching is timing-dependent (1..N batches for N events), so input
    /// assertions wait on the total event count, not the message count.
    func waitForInputEvents(count: Int, timeout: TimeInterval = 5) async -> [SimStreamInputEvent] {
        let deadline = Date().addingTimeInterval(timeout)
        while inputEventCount() < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return sent.compactMap { message -> [SimStreamInputEvent]? in
            guard case .input(let batch) = message else { return nil }
            return batch.events
        }.flatMap { $0 }
    }

    private func inputEventCount() -> Int {
        sent.reduce(0) { partial, message in
            guard case .input(let batch) = message else { return partial }
            return partial + batch.events.count
        }
    }
}

private final class FakePresenter: SimStreamFramePresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var _configs: [SimStreamConfig] = []
    private var _presented: [UInt64] = []
    private var _resets = 0
    var acceptFrames = true

    var configs: [SimStreamConfig] {
        lock.lock()
        defer { lock.unlock() }
        return _configs
    }
    var presented: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return _presented
    }
    var resets: Int {
        lock.lock()
        defer { lock.unlock() }
        return _resets
    }

    func applyConfig(_ config: SimStreamConfig) async {
        lock.withLock { _configs.append(config) }
    }

    func present(
        _ sampleBuffer: sending CMSampleBuffer, sequence: UInt64, isKeyframe: Bool
    ) async -> Bool {
        lock.withLock {
            guard acceptFrames else { return false }
            _presented.append(sequence)
            return true
        }
    }

    func reset() async {
        lock.withLock { _resets += 1 }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SimStreamViewerEvent] = []

    var events: [SimStreamViewerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    func append(_ event: SimStreamViewerEvent) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }
}

@Suite
struct SimStreamViewerEngineTests {
    /// A real H.264 keyframe + delta so sample-buffer creation succeeds.
    private static func encodedFixture() async throws -> (
        config: SimStreamConfig, keyframe: SimStreamFrame, delta: SimStreamFrame
    ) {
        let width = 96
        let height = 160
        let encoder = try SimStreamVideoEncoder(
            codec: .h264, width: width, height: height, bitsPerSecond: 1_000_000)
        let factory = SimStreamPixelBufferFactory()

        var encodedFrames: [SimStreamEncodedFrame] = []
        for step in 0..<2 {
            let buffer = try factory.makePixelBuffer(
                pixels: Data(repeating: UInt8(40 + step * 60), count: width * 4 * height),
                width: width, height: height, bytesPerRow: width * 4)
            encodedFrames.append(
                try await encoder.encode(
                    buffer, presentationMicroseconds: UInt64(step) * 16_666,
                    forceKeyframe: step == 0))
        }
        let config = SimStreamConfig(
            codec: .h264,
            pixelWidth: UInt32(width),
            pixelHeight: UInt32(height),
            displayScale: 3.0,
            orientation: .portrait,
            parameterSets: encodedFrames[0].parameterSets,
            nalUnitHeaderLength: encodedFrames[0].nalUnitHeaderLength
        )
        let frames = encodedFrames.enumerated().map { index, encoded in
            SimStreamFrame(
                sequence: UInt64(index + 1),
                flags: encoded.isKeyframe ? [.keyframe] : [],
                presentationMicroseconds: UInt64(index) * 16_666,
                payload: encoded.data
            )
        }
        return (config, frames[0], frames[1])
    }

    @Test
    func startsThenConfiguresThenAcksPresentedFrames() async throws {
        let fixture = try await Self.encodedFixture()
        let lane = FakeLane()
        let presenter = FakePresenter()
        let log = EventLog()
        let engine = SimStreamViewerEngine(
            presenter: presenter, maximumLongSidePixels: 1600, epoch: 1
        ) { log.append($0) }

        let runTask = Task { await engine.run(opener: { lane }) }
        // First outbound message must be start.
        var sent = await lane.waitForSent(count: 1)
        guard case .start(let start) = sent.first else {
            Issue.record("expected start first, got \(String(describing: sent.first))")
            return
        }
        #expect(start.epoch == 1)
        #expect(start.codecPreferences == [.hevc, .h264])

        await lane.hostSends(.config(fixture.config))
        await lane.hostSends(.frame(fixture.keyframe))
        await lane.hostSends(.frame(fixture.delta))

        sent = await lane.waitForSent(count: 3)
        let acks = sent.compactMap { message -> SimStreamAck? in
            guard case .ack(let ack) = message else { return nil }
            return ack
        }
        #expect(acks.map(\.sequence) == [1, 2])
        #expect(presenter.presented == [1, 2])
        #expect(presenter.configs.count == 1)

        await lane.hostFinishes()
        await runTask.value
        let sawCleanEnd = log.events.contains { event in
            if case .ended(clean: true) = event { return true } else { return false }
        }
        #expect(sawCleanEnd)
    }

    @Test
    func rejectedFramesAreNeverAckedAndTriggerKeyframeRequest() async throws {
        let fixture = try await Self.encodedFixture()
        let lane = FakeLane()
        let presenter = FakePresenter()
        presenter.acceptFrames = false
        let log = EventLog()
        let engine = SimStreamViewerEngine(
            presenter: presenter, maximumLongSidePixels: 1600, epoch: 1
        ) { log.append($0) }
        let runTask = Task { await engine.run(opener: { lane }) }
        _ = await lane.waitForSent(count: 1)

        await lane.hostSends(.config(fixture.config))
        for sequence in UInt64(1)...3 {
            var frame = fixture.keyframe
            frame = SimStreamFrame(
                sequence: sequence, flags: frame.flags,
                presentationMicroseconds: frame.presentationMicroseconds,
                payload: frame.payload)
            await lane.hostSends(.frame(frame))
        }
        let sent = await lane.waitForSent(count: 2)
        let ackCount = sent.filter { message in
            if case .ack = message { return true } else { return false }
        }.count
        #expect(ackCount == 0, "undisplayed frames must never be acked")
        let keyframeRequests = sent.filter { message in
            if case .keyframeRequest = message { return true } else { return false }
        }.count
        #expect(keyframeRequests == 1)
        #expect(presenter.resets == 1)

        await lane.hostFinishes()
        await runTask.value
    }

    @Test
    func sixConsecutivePresentFailuresEndTheAttempt() async throws {
        let fixture = try await Self.encodedFixture()
        let lane = FakeLane()
        let presenter = FakePresenter()
        presenter.acceptFrames = false
        let log = EventLog()
        let engine = SimStreamViewerEngine(
            presenter: presenter, maximumLongSidePixels: 1600, epoch: 1
        ) { log.append($0) }
        let runTask = Task { await engine.run(opener: { lane }) }
        _ = await lane.waitForSent(count: 1)
        await lane.hostSends(.config(fixture.config))
        for sequence in UInt64(1)...6 {
            await lane.hostSends(
                .frame(
                    SimStreamFrame(
                        sequence: sequence, flags: [.keyframe],
                        presentationMicroseconds: 0, payload: fixture.keyframe.payload)))
        }
        await runTask.value
        let sawFailedEnd = log.events.contains { event in
            if case .ended(clean: false) = event { return true } else { return false }
        }
        #expect(sawFailedEnd)
    }

    @Test
    func inputEventsFlushImmediatelyInOrder() async throws {
        let lane = FakeLane()
        let presenter = FakePresenter()
        let engine = SimStreamViewerEngine(
            presenter: presenter, maximumLongSidePixels: 1600, epoch: 1
        ) { _ in }
        let runTask = Task { await engine.run(opener: { lane }) }
        _ = await lane.waitForSent(count: 1)

        await engine.send(
            .touch(phase: .began, pointerID: 0, x: 0.5, y: 0.5, timestampMicroseconds: 1))
        await engine.send(
            .touch(phase: .ended, pointerID: 0, x: 0.5, y: 0.5, timestampMicroseconds: 2))
        await engine.send(.text("hi"))

        let events = await lane.waitForInputEvents(count: 3)
        let sent = await lane.waitForSent(count: 2)
        let batches = sent.compactMap { message -> SimStreamInputBatch? in
            guard case .input(let batch) = message else { return nil }
            return batch
        }
        #expect(events.count == 3)
        #expect(batches.map(\.sequence) == batches.map(\.sequence).sorted())
        if case .text(let text) = events.last {
            #expect(text == "hi")
        } else {
            Issue.record("text event out of order")
        }
        await lane.hostFinishes()
        await runTask.value
    }

    @Test
    func qualityChangeRenegotiatesOnTheLiveLane() async throws {
        let lane = FakeLane()
        let presenter = FakePresenter()
        let engine = SimStreamViewerEngine(
            presenter: presenter, maximumLongSidePixels: 2_000, epoch: 1
        ) { _ in }
        let runTask = Task { await engine.run(opener: { lane }) }
        _ = await lane.waitForSent(count: 1)

        await engine.updateQuality(maximumLongSidePixels: 800)
        // Same value again must not renegotiate.
        await engine.updateQuality(maximumLongSidePixels: 800)

        let sent = await lane.waitForSent(count: 2)
        let starts = sent.compactMap { message -> SimStreamStartRequest? in
            guard case .start(let request) = message else { return nil }
            return request
        }
        #expect(starts.map(\.maximumLongSidePixels) == [2_000, 800])
        #expect(starts.map(\.epoch) == [1, 1])
        await lane.hostFinishes()
        await runTask.value
    }

    @Test
    func frameBeforeConfigFailsClosed() async throws {
        let fixture = try await Self.encodedFixture()
        let lane = FakeLane()
        let presenter = FakePresenter()
        let log = EventLog()
        let engine = SimStreamViewerEngine(
            presenter: presenter, maximumLongSidePixels: 1600, epoch: 1
        ) { log.append($0) }
        let runTask = Task { await engine.run(opener: { lane }) }
        _ = await lane.waitForSent(count: 1)
        await lane.hostSends(.frame(fixture.keyframe))
        await runTask.value
        let sawFailedEnd = log.events.contains { event in
            if case .ended(clean: false) = event { return true } else { return false }
        }
        #expect(sawFailedEnd)
        #expect(presenter.presented.isEmpty)
    }
}

