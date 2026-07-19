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
        let updates = SchedulerUpdateRecorder()
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
        } deliver: { update in
            await updates.record(update)
        }

        await updates.waitForCount(1)
        let update = try #require(await updates.values.first)
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
        let updates = SchedulerUpdateRecorder()

        await scheduler.start(surfaceID: surfaceID, signal: signal) { revision in
            await recorder.record(revision)
            return await state.classification(revision: revision)
        } deliver: { update in
            await updates.record(update)
        }
        signal.markDirty()
        await updates.waitForCount(1)
        #expect(try #require(await updates.values.first).classification.state == .working)

        signal.markDirty()
        await recorder.waitForCount(2)
        await state.set(.idle)
        signal.markDirty()
        await updates.waitForCount(2)
        let next = try #require(await updates.values.last)
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
        let updates = SchedulerUpdateRecorder()

        await scheduler.start(surfaceID: surfaceID, signal: signal) { revision in
            await recorder.record(revision)
            if revision == 1 {
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
            }
            return makeClassification(revision == 1 ? .working : .idle, pid: Int32(revision))
        } deliver: { update in
            await updates.record(update)
        }
        signal.markDirty()
        await recorder.waitForCount(1)
        signal.markDirty()
        gate.continuation.yield(())

        await updates.waitForCount(1)
        let update = try #require(await updates.values.first)
        #expect(update.revision == 2)
        #expect(update.classification.state == .idle)
        #expect(await recorder.revisions == [1, 2])
        await scheduler.stopAll()
    }

    @Test
    func simultaneousSurfacesDeliverIndependently() async throws {
        let scheduler = immediateScheduler()
        let firstSignal = AgentTerminalDirtySignal()
        let secondSignal = AgentTerminalDirtySignal()
        let firstSurface = UUID()
        let secondSurface = UUID()
        let updates = SchedulerUpdateRecorder()

        await scheduler.start(surfaceID: firstSurface, signal: firstSignal) { _ in
            makeClassification(.working, pid: 11)
        } deliver: { update in
            await updates.record(update)
        }
        await scheduler.start(surfaceID: secondSurface, signal: secondSignal) { _ in
            makeClassification(.blocked, pid: 22)
        } deliver: { update in
            await updates.record(update)
        }
        firstSignal.markDirty()
        secondSignal.markDirty()

        await updates.waitForCount(2)
        let delivered = await updates.values
        #expect(Set(delivered.map(\.surfaceID)) == Set([firstSurface, secondSurface]))
        #expect(delivered.first(where: { $0.surfaceID == firstSurface })?.classification.state == .working)
        #expect(delivered.first(where: { $0.surfaceID == secondSurface })?.classification.state == .blocked)
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

private actor SchedulerUpdateRecorder {
    private(set) var values: [AgentTerminalDetectionUpdate] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ update: AgentTerminalDetectionUpdate) {
        values.append(update)
        let ready = waiters.filter { values.count >= $0.count }
        waiters.removeAll { values.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForCount(_ count: Int) async {
        if values.count >= count { return }
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
