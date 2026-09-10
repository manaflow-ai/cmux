import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct SimulatorFramePresentationPipelineTests {
    @Test func slowDecoderPresentsFreshFramesWithoutUnboundedDecodeWork() async {
        let decoder = ControlledSimulatorFrameDecoder()
        let pipeline = SimulatorFramePresentationPipeline<Int> { frame in
            await decoder.decode(frame)
        }
        var events = pipeline.events.makeAsyncIterator()

        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 1))
        await decoder.waitUntilStarted(sequence: 1)
        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 2))
        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 3))

        #expect(pipeline.progress.activeSequence == 1)
        #expect(pipeline.progress.pendingSequence == 3)
        #expect(await decoder.maximumConcurrentDecodeCount() == 1)

        await decoder.complete(sequence: 1)
        guard let firstEvent = await events.next(),
              case .presented(let firstFrame) = firstEvent else {
            Issue.record("Expected the first completed decode to present")
            return
        }
        await decoder.waitUntilStarted(sequence: 3)
        #expect(firstFrame.sequence == 1)
        #expect(pipeline.presented?.frame.sequence == 1)
        #expect(pipeline.progress.activeSequence == 3)
        #expect(pipeline.progress.pendingSequence == nil)

        await decoder.complete(sequence: 3)
        guard let newestEvent = await events.next(),
              case .presented(let newestFrame) = newestEvent else {
            Issue.record("Expected the newest pending decode to present")
            return
        }

        #expect(newestFrame.sequence == 3)
        #expect(pipeline.presented?.frame.sequence == 3)
        #expect(pipeline.progress.presentedSequence == 3)
        #expect(await decoder.startedSequences() == [1, 3])
        #expect(await decoder.maximumConcurrentDecodeCount() == 1)
    }

    @Test func panelReplacementFencesCancelledDecodeAndPresentsReplacementPanel() async {
        let decoder = ControlledSimulatorFrameDecoder()
        let pipeline = SimulatorFramePresentationPipeline<Int> { frame in
            await decoder.decode(frame)
        }
        var events = pipeline.events.makeAsyncIterator()

        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 7))
        await decoder.waitUntilStarted(sequence: 7)
        pipeline.submit(Self.frame(panelID: "panel-b", sequence: 1))

        #expect(pipeline.progress.panelID == "panel-b")
        #expect(pipeline.progress.pendingSequence == 1)

        await decoder.complete(sequence: 7)
        guard let discardedEvent = await events.next(),
              case .discarded(let discardedFrame) = discardedEvent else {
            Issue.record("Expected the replaced panel decode to be discarded")
            return
        }
        #expect(discardedFrame.panelID == "panel-a")
        await decoder.waitUntilStarted(sequence: 1)
        #expect(pipeline.presented?.frame.panelID == nil)

        await decoder.complete(sequence: 1)
        guard let replacementEvent = await events.next(),
              case .presented(let replacementFrame) = replacementEvent else {
            Issue.record("Expected the replacement panel to present")
            return
        }

        #expect(replacementFrame.panelID == "panel-b")
        #expect(pipeline.presented?.frame.panelID == "panel-b")
        #expect(pipeline.presented?.frame.sequence == 1)
        #expect(await decoder.maximumConcurrentDecodeCount() == 1)
    }

    @Test func remountAcceptsSameFrameThatWasCancelledOnDisappear() async {
        let decoder = ControlledSimulatorFrameDecoder()
        let pipeline = SimulatorFramePresentationPipeline<Int> { frame in
            await decoder.decode(frame)
        }
        var events = pipeline.events.makeAsyncIterator()
        let frame = Self.frame(panelID: "panel-a", sequence: 9)

        pipeline.submit(frame)
        await decoder.waitUntilStarted(sequence: 9)
        pipeline.cancel()
        pipeline.submit(frame)

        #expect(pipeline.progress.pendingSequence == 9)
        await decoder.complete(sequence: 9)
        guard let discardedEvent = await events.next(),
              case .discarded = discardedEvent else {
            Issue.record("Expected the unmounted decode to be discarded")
            return
        }
        await decoder.waitUntilStartedCount(2)
        await decoder.complete(sequence: 9)
        guard let remountedEvent = await events.next(),
              case .presented(let remountedFrame) = remountedEvent else {
            Issue.record("Expected the remounted frame to present")
            return
        }

        #expect(remountedFrame.sequence == 9)
        #expect(pipeline.presented?.frame.sequence == 9)
        #expect(await decoder.maximumConcurrentDecodeCount() == 1)
    }

    @Test func repeatedDecodeFailuresSignalStallAndSuccessResetsFailureCount() async {
        let pipeline = SimulatorFramePresentationPipeline<Int> { frame in
            frame.sequence == 4 ? 4 : nil
        }
        var events = pipeline.events.makeAsyncIterator()

        for sequence in 1...3 {
            pipeline.submit(Self.frame(panelID: "panel-a", sequence: UInt64(sequence)))
            guard let failureEvent = await events.next(),
                  case .decodeFailed(let frame) = failureEvent else {
                Issue.record("Expected a decode failure")
                return
            }
            #expect(frame.sequence == UInt64(sequence))
        }

        guard let stalledEvent = await events.next(),
              case .presentationStalled(let stalledFrame) = stalledEvent else {
            Issue.record("Expected the third decode failure to signal a stall")
            return
        }
        #expect(stalledFrame.sequence == 3)
        #expect(pipeline.progress.consecutiveFailureCount == 0)
        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 4))
        guard let recoveryEvent = await events.next(),
              case .presented(let recoveryFrame) = recoveryEvent else {
            Issue.record("Expected a successful recovery presentation")
            return
        }
        #expect(recoveryFrame.sequence == 4)
        #expect(pipeline.presented?.frame.sequence == 4)
        #expect(pipeline.progress.consecutiveFailureCount == 0)
    }

    @Test func cachedSameSequenceCanBeDecodedAgainDuringRecovery() async {
        let decoder = ControlledSimulatorFrameDecoder()
        let pipeline = SimulatorFramePresentationPipeline<Int> { frame in
            await decoder.decode(frame)
        }
        var events = pipeline.events.makeAsyncIterator()
        let frame = Self.frame(panelID: "panel-a", sequence: 5)

        pipeline.submit(frame)
        await decoder.waitUntilStarted(sequence: 5)
        await decoder.complete(sequence: 5)
        guard let firstEvent = await events.next(),
              case .presented = firstEvent else {
            Issue.record("Expected the original frame to present")
            return
        }

        pipeline.submit(frame, allowDuplicateSequence: true)
        await decoder.waitUntilStartedCount(2)
        await decoder.complete(sequence: 5)
        guard let replayEvent = await events.next(),
              case .presented(let replayedFrame) = replayEvent else {
            Issue.record("Expected the cached frame replay to present")
            return
        }

        #expect(replayedFrame.sequence == 5)
        #expect(await decoder.startedSequences() == [5, 5])
    }

    private static func frame(panelID: String, sequence: UInt64) -> MobileSimulatorFrameEvent {
        MobileSimulatorFrameEvent(
            panelID: panelID,
            sequence: sequence,
            format: .jpeg,
            pixelWidth: 1,
            pixelHeight: 1,
            displayScale: 1,
            dataBase64: "frame-\(sequence)"
        )
    }
}

private actor ControlledSimulatorFrameDecoder {
    private var continuations: [UInt64: CheckedContinuation<Int, Never>] = [:]
    private var startWaiters: [UInt64: [CheckedContinuation<Void, Never>]] = [:]
    private var startCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var starts: [UInt64] = []
    private var activeDecodeCount = 0
    private var maximumActiveDecodeCount = 0

    func decode(_ frame: MobileSimulatorFrameEvent) async -> Int? {
        starts.append(frame.sequence)
        activeDecodeCount += 1
        maximumActiveDecodeCount = max(maximumActiveDecodeCount, activeDecodeCount)
        let waiters = startWaiters.removeValue(forKey: frame.sequence) ?? []
        waiters.forEach { $0.resume() }
        for index in startCountWaiters.indices.reversed()
        where starts.count >= startCountWaiters[index].0 {
            startCountWaiters.remove(at: index).1.resume()
        }
        let result = await withCheckedContinuation { continuation in
            continuations[frame.sequence] = continuation
        }
        activeDecodeCount -= 1
        return result
    }

    func waitUntilStarted(sequence: UInt64) async {
        if starts.contains(sequence) { return }
        await withCheckedContinuation { continuation in
            startWaiters[sequence, default: []].append(continuation)
        }
    }

    func complete(sequence: UInt64) {
        continuations.removeValue(forKey: sequence)?.resume(returning: Int(sequence))
    }

    func waitUntilStartedCount(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { continuation in
            startCountWaiters.append((count, continuation))
        }
    }

    func startedSequences() -> [UInt64] { starts }
    func maximumConcurrentDecodeCount() -> Int { maximumActiveDecodeCount }
}
