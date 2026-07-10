import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorWorker

@Suite("Simulator tool operation scheduling")
struct SimulatorToolOperationSchedulingTests {
    @Test("A deadline fails promptly but keeps its lane occupied until cancellation unwinds")
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
        guard case let .requestFailure(requestID, failure) = try await fixture.receiveAsync() else {
            Issue.record("Expected the timed-out operation failure")
            return
        }
        #expect(requestID == firstRequest)
        #expect(failure.code == "worker_operation_timed_out")

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
        coordinator.enqueueToolOperation(
            lane: .maintenance,
            requestIdentifier: UUID(),
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

        var failures: [UUID: SimulatorFailure] = [:]
        for _ in 0..<2 {
            guard case let .requestFailure(requestID, failure) = try await fixture.receiveAsync()
            else {
                Issue.record("Expected a correlated cancellation failure")
                return
            }
            failures[requestID] = failure
        }
        #expect(failures[rejectedRequest]?.code == "worker_operation_cancelling")

        await gate.release()
        for _ in 0..<1_000 {
            if coordinator.cancelingToolOperationLanes.isEmpty { break }
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
}
