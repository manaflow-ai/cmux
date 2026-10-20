import Darwin
import Foundation
import Testing
@testable import CmuxSimulator
@testable import CmuxSimulatorWorker

@Suite("Simulator accessibility request scheduling")
struct SimulatorAccessibilityRequestSchedulingTests {
    @Test("A blocked foreground read does not delay worker input acknowledgments")
    @MainActor
    func foregroundReadDoesNotBlockPing() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "DEVICE"
        let requestIdentifier = UUID()

        #expect(await coordinator.handle(.requestForegroundApplication(requestIdentifier)))
        await executor.waitForForegroundReadCount(1)
        #expect(await coordinator.handle(.ping(42)))
        #expect(try fixture.receive() == .ack(42))

        await executor.releaseForegroundRead()
        #expect(try await fixture.receiveAsync() == .foregroundApplication(
            requestID: requestIdentifier,
            GatedAccessibilityExecutor.application
        ))
    }

    @Test("Foreground reads coalesce behind one bounded private query")
    @MainActor
    func foregroundReadsAreBoundedAndCoalesced() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture(nonblockingWrites: true)
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "DEVICE"
        let requestIdentifiers = (0...SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount)
            .map { _ in UUID() }

        for requestIdentifier in requestIdentifiers {
            #expect(await coordinator.handle(.requestForegroundApplication(requestIdentifier)))
        }

        guard case let .requestFailure(requestID, failure) = try fixture.receive() else {
            Issue.record("Expected the ninth foreground request to fail immediately")
            return
        }
        #expect(requestID == requestIdentifiers.last)
        #expect(failure.code == "foreground_request_busy")
        await executor.waitForForegroundReadCount(1)
        #expect(await executor.foregroundReadCount == 1)

        let responses = Task.detached {
            try (0..<SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount).map { _ in
                try fixture.receive()
            }
        }
        await executor.releaseForegroundRead()
        var completedIdentifiers: Set<UUID> = []
        for response in try await responses.value {
            guard case let .foregroundApplication(requestID, application) = response else {
                Issue.record("Expected a coalesced foreground response")
                return
            }
            completedIdentifiers.insert(requestID)
            #expect(application == GatedAccessibilityExecutor.application)
        }
        #expect(completedIdentifiers == Set(requestIdentifiers.dropLast()))
        #expect(await executor.foregroundReadCount == 1)
    }

    @Test("A foreground result from a detached device is discarded")
    @MainActor
    func staleForegroundResultIsDiscarded() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "OLD"

        #expect(await coordinator.handle(.requestForegroundApplication(UUID())))
        await executor.waitForForegroundReadCount(1)
        coordinator.currentDeviceIdentifier = "NEW"
        await executor.releaseForegroundRead()
        while coordinator.foregroundApplicationTask != nil {
            await Task.yield()
        }

        #expect(await coordinator.handle(.ping(7)))
        #expect(try fixture.receive() == .ack(7))
    }

    @Test("A blocked accessibility snapshot releases the ordered worker consumer")
    @MainActor
    func accessibilitySnapshotDoesNotBlockConsumer() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "DEVICE"
        coordinator.currentDisplay = Self.display
        let completion = WorkerHandleCompletion()
        let requestIdentifier = UUID()

        let requestTask = Task { @MainActor in
            let result = await coordinator.handle(.requestAccessibility(requestIdentifier))
            await completion.finish(result)
        }
        await executor.waitForAccessibilityReadCount(1)
        for _ in 0..<200 where await completion.result == nil {
            await Task.yield()
        }
        #expect(await completion.result == true)

        #expect(await coordinator.handle(.ping(99)))
        #expect(try fixture.receive() == .ack(99))
        await executor.releaseAccessibilityRead()
        await requestTask.value
        #expect(try await fixture.receiveAsync() == .accessibility(
            requestID: requestIdentifier,
            GatedAccessibilityExecutor.snapshot
        ))
    }

    @Test("Camera setup releases the ordered worker consumer")
    @MainActor
    func cameraSetupDoesNotBlockConsumer() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        let completion = WorkerHandleCompletion()

        let requestTask = Task { @MainActor in
            let result = await coordinator.handle(.configureCamera(
                requestID: UUID(),
                configuration: .placeholder
            ))
            await completion.finish(result)
        }
        await executor.waitForForegroundReadCount(1)
        for _ in 0..<200 where await completion.result == nil {
            await Task.yield()
        }
        #expect(await completion.result == true)

        #expect(await coordinator.handle(.ping(100)))
        #expect(try fixture.receive() == .ack(100))
        await executor.releaseForegroundRead()
        await requestTask.value
        await coordinator.shutdown()
    }

    static let display = SimulatorDisplayMetadata(
        width: 1_200,
        height: 2_400,
        orientation: .portrait,
        scale: 3
    )
}
