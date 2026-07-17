import Foundation
import Testing
@testable import CmuxTerminalCore

@Suite
struct AgentTerminalStateDetectionSchedulerTests {
    @Test
    func bufferingNewestCoalescesBurstAndPublishesLatestRevision() async throws {
        let scheduler = AgentTerminalStateDetectionScheduler(
            clock: AgentTerminalDetectionClock(now: { .zero }, sleep: { _ in }),
            configuration: AgentTerminalDetectionConfiguration(quietWindow: .zero, maximumLatency: .zero)
        )
        let signal = AgentTerminalDirtySignal()
        let surfaceID = UUID()
        let recorder = SchedulerEvaluationRecorder()
        var updates = await scheduler.updates().makeAsyncIterator()
        let identity = AgentTerminalProcessIdentity(
            pid: 7,
            startSeconds: 1,
            startMicroseconds: 2,
            runtimeGeneration: 3
        )

        signal.markDirty()
        signal.markDirty()
        await scheduler.start(surfaceID: surfaceID, signal: signal) { revision in
            await recorder.record(revision)
            return AgentTerminalStateClassification(
                familyID: "codex",
                statusKey: "codex",
                state: .working,
                processIdentity: identity
            )
        }

        let update = try #require(await updates.next())
        #expect(update.revision == 2)
        #expect(await recorder.revisions == [2])
        await scheduler.stopAll()
    }

    @Test
    func unchangedClassificationDoesNotPublishAgain() async throws {
        let scheduler = immediateScheduler()
        let signal = AgentTerminalDirtySignal()
        let surfaceID = UUID()
        let state = SchedulerClassificationState()
        let recorder = SchedulerEvaluationRecorder()
        var updates = await scheduler.updates().makeAsyncIterator()

        await scheduler.start(surfaceID: surfaceID, signal: signal) { revision in
            await recorder.record(revision)
            return await state.classification(revision: revision)
        }
        signal.markDirty()
        #expect(try #require(await updates.next()).classification.state == .working)

        signal.markDirty()
        await recorder.waitForCount(2)
        await state.set(.idle)
        signal.markDirty()
        let next = try #require(await updates.next())
        #expect(next.revision == 3)
        #expect(next.classification.state == .idle)
        await scheduler.stopAll()
    }

    @Test
    func resultThatBecomesStaleDuringEvaluationIsDiscarded() async throws {
        let scheduler = immediateScheduler()
        let signal = AgentTerminalDirtySignal()
        let surfaceID = UUID()
        let recorder = SchedulerEvaluationRecorder()
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        var updates = await scheduler.updates().makeAsyncIterator()

        await scheduler.start(surfaceID: surfaceID, signal: signal) { revision in
            await recorder.record(revision)
            if revision == 1 {
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            return makeClassification(revision == 1 ? .working : .idle, pid: Int32(revision))
        }
        signal.markDirty()
        await recorder.waitForCount(1)
        signal.markDirty()
        gate.continuation.yield(())

        let update = try #require(await updates.next())
        #expect(update.revision == 2)
        #expect(update.classification.state == .idle)
        #expect(await recorder.revisions == [1, 2])
        await scheduler.stopAll()
    }

    private func immediateScheduler() -> AgentTerminalStateDetectionScheduler {
        AgentTerminalStateDetectionScheduler(
            clock: AgentTerminalDetectionClock(now: { .zero }, sleep: { _ in }),
            configuration: AgentTerminalDetectionConfiguration(quietWindow: .zero, maximumLatency: .zero)
        )
    }
}

private actor SchedulerEvaluationRecorder {
    private(set) var revisions: [UInt64] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ revision: UInt64) {
        revisions.append(revision)
        let ready = waiters.filter { revisions.count >= $0.count }
        waiters.removeAll { revisions.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForCount(_ count: Int) async {
        if revisions.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor SchedulerClassificationState {
    private var state: AgentTerminalSemanticState = .working

    func set(_ state: AgentTerminalSemanticState) {
        self.state = state
    }

    func classification(revision: UInt64) -> AgentTerminalStateClassification {
        makeClassification(state)
    }
}

private func makeClassification(
    _ state: AgentTerminalSemanticState,
    pid: Int32 = 7
) -> AgentTerminalStateClassification {
    AgentTerminalStateClassification(
        familyID: "codex",
        statusKey: "codex",
        state: state,
        processIdentity: AgentTerminalProcessIdentity(
            pid: pid,
            startSeconds: 1,
            startMicroseconds: 2,
            runtimeGeneration: 3
        )
    )
}
