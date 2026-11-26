import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator tool operation scheduling")
struct SimulatorToolOperationSchedulingTests {
    @Test("A deadline joins cancellation before failing and keeps its lane occupied")
    @MainActor
    func deadlineWaitsForUnwind() async throws {
        let fixture = try ToolOutputFixture()
        let sleeper = FirstImmediateToolSleeper()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            toolOperationSleeper: sleeper
        )
        let gate = ToolOperationGate()
        let queuedProbe = ToolOperationProbe()
        let firstRequest = UUID()

        coordinator.enqueueToolOperation(
            lane: .camera,
            requestIdentifier: firstRequest,
            timeout: .seconds(1)
        ) { _, _ in
            await gate.run()
        }
        await gate.waitUntilStarted()
        for _ in 0..<1_000 where coordinator.timedOutToolOperationGenerations.isEmpty {
            await Task.yield()
        }
        #expect(!coordinator.timedOutToolOperationGenerations.isEmpty)

        coordinator.enqueueToolOperation(
            lane: .camera,
            requestIdentifier: UUID(),
            timeout: .seconds(1)
        ) { _, _ in
            await queuedProbe.markStarted()
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!(await queuedProbe.started))

        await gate.release()
        guard case let .requestFailure(requestID, failure) = try await fixture.receiveAsync() else {
            Issue.record("Expected the timed-out operation failure")
            return
        }
        #expect(requestID == firstRequest)
        #expect(failure.code == "worker_operation_timed_out")
        for _ in 0..<1_000 {
            if await queuedProbe.started { break }
            await Task.yield()
        }
        #expect(await queuedProbe.started)
        await coordinator.cancelToolOperations()
    }

    @Test("Device cancellation rejects new lane work until the old body returns")
    @MainActor
    func cancellationClosesLaneAdmission() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            toolOperationSleeper: BlockingToolSleeper()
        )
        let gate = ToolOperationGate()
        let activeRequest = UUID()
        coordinator.enqueueToolOperation(
            lane: .maintenance,
            requestIdentifier: activeRequest,
            timeout: .seconds(1)
        ) { _, _ in
            await gate.run()
        }
        await gate.waitUntilStarted()

        coordinator.cancelToolOperationsWithoutWaiting()
        let rejectedRequest = UUID()
        coordinator.enqueueToolOperation(
            lane: .maintenance,
            requestIdentifier: rejectedRequest,
            timeout: .seconds(1)
        ) { _, _ in }

        guard case let .requestFailure(rejectedID, rejectedFailure) =
            try await fixture.receiveAsync() else {
            Issue.record("Expected the lane-admission failure")
            return
        }
        #expect(rejectedID == rejectedRequest)
        #expect(rejectedFailure.code == "worker_operation_cancelling")

        await gate.release()
        guard case let .requestFailure(cancelledID, cancelledFailure) =
            try await fixture.receiveAsync() else {
            Issue.record("Expected the active-operation cancellation")
            return
        }
        #expect(cancelledID == activeRequest)
        #expect(cancelledFailure.code == "worker_operation_cancelled")
        for _ in 0..<1_000 {
            if coordinator.cancelingToolOperationLanes.isEmpty { break }
            await Task.yield()
        }
        #expect(coordinator.cancelingToolOperationLanes.isEmpty)
        await coordinator.cancelToolOperations()
    }

    @Test("Lifecycle cancellation preserves a mutation that commits while joining")
    @MainActor
    func lifecycleCancellationPreservesCommittedMutation() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            toolOperationSleeper: BlockingToolSleeper()
        )
        let gate = ToolOperationGate()
        let request = UUID()
        coordinator.enqueueToolOperation(
            lane: .maintenance,
            requestIdentifier: request,
            timeout: .seconds(60)
        ) { coordinator, generation in
            await gate.run()
            guard coordinator.toolOperationDidCommit(generation) else { return }
            coordinator.send(.privatePrivacy(requestID: request, succeeded: true))
        }
        await gate.waitUntilStarted()

        coordinator.cancelToolOperationsWithoutWaiting()
        await gate.release()
        guard case let .privatePrivacy(requestID, succeeded) = try await fixture.receiveAsync()
        else {
            Issue.record("Expected the committed mutation success")
            return
        }
        #expect(requestID == request)
        #expect(succeeded)
        for _ in 0..<1_000 where !coordinator.cancelingToolOperationLanes.isEmpty {
            await Task.yield()
        }
        #expect(coordinator.cancelingToolOperationLanes.isEmpty)
        await coordinator.cancelToolOperations()
    }

    @Test("Process-exit teardown abandons a cancellation-blind tool body")
    @MainActor
    func processExitDoesNotAwaitCancellationBlindTool() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(channel: fixture.worker)
        let gate = ToolOperationGate()
        coordinator.enqueueToolOperation(
            lane: .camera,
            requestIdentifier: UUID(),
            timeout: .seconds(60)
        ) { _, _ in
            await gate.run()
        }
        await gate.waitUntilStarted()

        coordinator.prepareForProcessExit()

        #expect(coordinator.cancelingToolOperationLanes.contains(.camera))
        await gate.release()
        for _ in 0..<1_000 {
            if coordinator.toolOperationTasks.isEmpty { break }
            await Task.yield()
        }
        #expect(coordinator.toolOperationTasks.isEmpty)
    }

    @Test("A cancellation-blind timed-out lane terminates the isolated worker after grace")
    @MainActor
    func cancellationBlindTimeoutTerminatesWorker() async throws {
        let fixture = try ToolOutputFixture()
        let terminator = ToolOperationTerminationProbe()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            toolOperationSleeper: ImmediateHIDSleeper(),
            toolOperationCancellationGrace: .milliseconds(1),
            toolOperationTerminator: { terminator.terminate() }
        )
        let gate = ToolOperationGate()
        let request = UUID()
        coordinator.enqueueToolOperation(
            lane: .camera,
            requestIdentifier: request,
            timeout: .seconds(1)
        ) { _, _ in
            await gate.run()
        }
        await gate.waitUntilStarted()
        for _ in 0..<1_000 where terminator.count == 0 { await Task.yield() }
        #expect(terminator.count == 1)

        await gate.release()
        guard case let .requestFailure(requestID, failure) = try await fixture.receiveAsync() else {
            Issue.record("Expected the timed-out operation failure")
            return
        }
        #expect(requestID == request)
        #expect(failure.code == "worker_operation_timed_out")
        await coordinator.cancelToolOperations()
    }

    @Test("A mutation committed while deadline cancellation joins returns success")
    @MainActor
    func committedMutationWinsDeadlineJoin() async throws {
        let fixture = try ToolOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            toolOperationSleeper: FirstImmediateToolSleeper()
        )
        let gate = ToolOperationGate()
        let request = UUID()
        coordinator.enqueueToolOperation(
            lane: .maintenance,
            requestIdentifier: request,
            timeout: .seconds(1)
        ) { coordinator, generation in
            await gate.run()
            guard coordinator.toolOperationDidCommit(generation) else { return }
            coordinator.send(.privatePrivacy(requestID: request, succeeded: true))
        }
        await gate.waitUntilStarted()
        for _ in 0..<1_000 where coordinator.timedOutToolOperationGenerations.isEmpty {
            await Task.yield()
        }
        #expect(!coordinator.timedOutToolOperationGenerations.isEmpty)

        await gate.release()
        guard case let .privatePrivacy(requestID, succeeded) = try await fixture.receiveAsync()
        else {
            Issue.record("Expected the committed mutation success")
            return
        }
        #expect(requestID == request)
        #expect(succeeded)
        await coordinator.cancelToolOperations()
    }

    @Test("Device shutdown is bounded when a tool body ignores cancellation")
    @MainActor
    func shutdownTerminatesCancellationBlindWorker() async throws {
        let fixture = try ToolOutputFixture()
        let sleeper = CancellationGraceToolSleeper()
        let terminator = ToolOperationTerminationProbe()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            toolOperationSleeper: sleeper,
            toolOperationCancellationGrace: .milliseconds(1),
            toolOperationTerminator: { terminator.terminate() }
        )
        let gate = ToolOperationGate()
        coordinator.enqueueToolOperation(
            lane: .camera,
            requestIdentifier: UUID(),
            timeout: .seconds(60)
        ) { _, _ in
            await gate.run()
        }
        await gate.waitUntilStarted()
        await sleeper.waitUntilFirstSleepStarts()

        let completion = ToolOperationProbe()
        let shutdownTask = Task { @MainActor in
            await coordinator.cancelToolOperations()
            await completion.markStarted()
        }
        for _ in 0..<1_000 where terminator.count == 0 { await Task.yield() }

        #expect(terminator.count == 1)
        #expect(await completion.started)
        await gate.release()
        await shutdownTask.value
    }
}
