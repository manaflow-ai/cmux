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

        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 1))
        await decoder.waitUntilStarted(sequence: 1)
        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 2))
        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 3))

        #expect(pipeline.progress.activeSequence == 1)
        #expect(pipeline.progress.pendingSequence == 3)
        #expect(await decoder.maximumConcurrentDecodeCount() == 1)

        await decoder.complete(sequence: 1)
        await decoder.waitUntilStarted(sequence: 3)
        #expect(pipeline.presented?.frame.sequence == 1)
        #expect(pipeline.progress.activeSequence == 3)
        #expect(pipeline.progress.pendingSequence == nil)

        await decoder.complete(sequence: 3)
        await pipeline.waitUntilIdleForTesting()

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

        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 7))
        await decoder.waitUntilStarted(sequence: 7)
        pipeline.submit(Self.frame(panelID: "panel-b", sequence: 1))

        #expect(pipeline.progress.panelID == "panel-b")
        #expect(pipeline.progress.pendingSequence == 1)

        await decoder.complete(sequence: 7)
        await decoder.waitUntilStarted(sequence: 1)
        #expect(pipeline.presented?.frame.panelID == nil)

        await decoder.complete(sequence: 1)
        await pipeline.waitUntilIdleForTesting()

        #expect(pipeline.presented?.frame.panelID == "panel-b")
        #expect(pipeline.presented?.frame.sequence == 1)
        #expect(await decoder.maximumConcurrentDecodeCount() == 1)
    }

    @Test func remountAcceptsSameFrameThatWasCancelledOnDisappear() async {
        let decoder = ControlledSimulatorFrameDecoder()
        let pipeline = SimulatorFramePresentationPipeline<Int> { frame in
            await decoder.decode(frame)
        }
        let frame = Self.frame(panelID: "panel-a", sequence: 9)

        pipeline.submit(frame)
        await decoder.waitUntilStarted(sequence: 9)
        pipeline.cancel()
        pipeline.submit(frame)

        #expect(pipeline.progress.pendingSequence == 9)
        await decoder.complete(sequence: 9)
        await decoder.waitUntilStartedCount(2)
        await decoder.complete(sequence: 9)
        await pipeline.waitUntilIdleForTesting()

        #expect(pipeline.presented?.frame.sequence == 9)
        #expect(await decoder.maximumConcurrentDecodeCount() == 1)
    }

    @Test func repeatedDecodeFailuresSignalStallAndSuccessResetsFailureCount() async {
        var stalledSequences: [UInt64] = []
        let pipeline = SimulatorFramePresentationPipeline<Int>(
            decoder: { frame in frame.sequence == 4 ? 4 : nil },
            onEvent: { event in
                if case .presentationStalled(let frame) = event {
                    stalledSequences.append(frame.sequence)
                }
            }
        )

        for sequence in 1...3 {
            pipeline.submit(Self.frame(panelID: "panel-a", sequence: UInt64(sequence)))
            await pipeline.waitUntilIdleForTesting()
        }

        #expect(stalledSequences == [3])
        #expect(pipeline.progress.consecutiveFailureCount == 0)
        pipeline.submit(Self.frame(panelID: "panel-a", sequence: 4))
        await pipeline.waitUntilIdleForTesting()
        #expect(pipeline.presented?.frame.sequence == 4)
        #expect(pipeline.progress.consecutiveFailureCount == 0)
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
