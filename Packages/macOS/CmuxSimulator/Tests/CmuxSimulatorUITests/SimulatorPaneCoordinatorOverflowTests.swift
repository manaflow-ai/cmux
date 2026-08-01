import CmuxSimulator
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane bounded output")
struct SimulatorPaneCoordinatorOverflowTests {
    @Test("Input release clears a retained semantic touch")
    @MainActor
    func inputReleaseClearsRetainedSemanticTouch() {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        coordinator.holdUIAutomationTouch(
            elementRef: "e1_1",
            point: SimulatorPoint(x: 0.5, y: 0.5),
            display: nil
        )

        coordinator.setActive(false)

        #expect(!coordinator.hasHeldUIAutomationTouch)
    }

    @Test("Failed worker touch recovery clears a retained semantic touch")
    @MainActor
    func failedWorkerTouchClearsRetainedSemanticTouch() async {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(
                devices: [],
                failsInteractiveAction: true
            )
        )
        coordinator.holdUIAutomationTouch(
            elementRef: "e1_1",
            point: SimulatorPoint(x: 0.5, y: 0.5),
            display: nil
        )

        do {
            _ = try await coordinator.perform(.interactive(.touch(
                events: [SimulatorPointerEvent(
                    phase: .ended,
                    primary: SimulatorPoint(x: 0.5, y: 0.5)
                )],
                holdMilliseconds: 0
            )))
            Issue.record("Expected the fixture touch to fail")
        } catch {}

        #expect(!coordinator.hasHeldUIAutomationTouch)
    }

    @Test("Semantic snapshot preparation yields the main actor")
    @MainActor
    func semanticSnapshotPreparationYieldsMainActor() async throws {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        var preparationStarted = false
        var preparationFinished = false
        let preparation = Task { @MainActor in
            preparationStarted = true
            for capturedAtMilliseconds in 0..<64 {
                _ = try await coordinator.recordUIAutomationSnapshot(
                    Self.maximumSnapshot(),
                    simulatorID: "DEVICE",
                    capturedAtMilliseconds: Int64(capturedAtMilliseconds)
                )
            }
            preparationFinished = true
        }

        while !preparationStarted {
            await Task.yield()
        }

        #expect(!preparationFinished)
        preparation.cancel()
        _ = await preparation.result
    }

    @Test("A dropped UI mutation preserves the last accepted semantic snapshot")
    @MainActor
    func droppedMutationPreservesSnapshot() async throws {
        let coordinator = SimulatorPaneCoordinator(
            client: SimulatorPaneClientSpy(devices: [])
        )
        for sequence in 0..<SimulatorPaneCoordinator.maximumOutgoingMessageCount {
            #expect(coordinator.enqueue(.ping(UInt64(sequence))))
        }
        let record = try await coordinator.recordUIAutomationSnapshot(
            Self.snapshot(),
            simulatorID: "DEVICE",
            capturedAtMilliseconds: 1_000
        )

        #expect(!coordinator.enqueue(.key(
            SimulatorKeyEvent(usage: 4, phase: .down)
        )))
        #expect(
            try coordinator.currentUIAutomationSnapshot(
                nowMilliseconds: 1_001
            ).snapshot.sequence == record.snapshot.sequence
        )
    }

    @Test("Outgoing overflow releases held input and stops the worker")
    @MainActor
    func outgoingOverflow() async {
        let device = Self.device()
        let client = SimulatorPaneClientSpy(devices: [device])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.reloadDevices()
        let keyDown = SimulatorWorkerInbound.key(SimulatorKeyEvent(usage: 4, phase: .down))
        for _ in 0..<SimulatorPaneCoordinator.maximumOutgoingMessageCount {
            coordinator.enqueue(keyDown)
        }
        coordinator.enqueue(.key(SimulatorKeyEvent(usage: 4, phase: .up)))

        for _ in 0..<1_000 {
            if await client.invalidationCount() > 0 { break }
            await Task.yield()
        }

        #expect(coordinator.failure?.code == "simulator_outgoing_queue_overflow")
        #expect(coordinator.status == .workerCrashed)
        #expect(await client.messages().contains(.releaseInputs))
        #expect(await client.invalidationCount() == 1)
        #expect(await client.stopCount() == 0)

        coordinator.recover()
        for _ in 0..<1_000 {
            if await client.activations().count == 1 { break }
            await Task.yield()
        }
        coordinator.enqueue(keyDown)
        let keyUp = SimulatorWorkerInbound.key(SimulatorKeyEvent(usage: 4, phase: .up))
        coordinator.enqueue(keyUp)
        for _ in 0..<1_000 {
            if Array((await client.messages()).suffix(2)) == [keyDown, keyUp] { break }
            await Task.yield()
        }

        #expect(await client.activations().count == 1)
        #expect(Array((await client.messages()).suffix(2)) == [keyDown, keyUp])
        await coordinator.close()
    }

    @Test("Event observation resubscribes once after worker restart")
    @MainActor
    func resubscribesAfterEventOverflow() async {
        let client = RestartingEventClient()
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()

        for _ in 0..<1_000 {
            if await client.subscriptionCount() == 1 { break }
            await Task.yield()
        }
        await client.finishSubscription(at: 0)
        for _ in 0..<1_000 {
            if await client.subscriptionCount() == 2 { break }
            await Task.yield()
        }
        await client.emit(.message(.status(.streaming)), to: 1)
        for _ in 0..<1_000 {
            if coordinator.status == .streaming { break }
            await Task.yield()
        }

        #expect(await client.subscriptionCount() == 2)
        #expect(coordinator.status == .streaming)

        await client.finishSubscription(at: 1)
        for _ in 0..<100 { await Task.yield() }
        #expect(await client.subscriptionCount() == 2)

        coordinator.recover()
        for _ in 0..<1_000 {
            if await client.subscriptionCount() == 3 { break }
            await Task.yield()
        }
        await client.emit(.message(.status(.streaming)), to: 2)
        for _ in 0..<1_000 {
            if coordinator.status == .streaming { break }
            await Task.yield()
        }

        #expect(await client.subscriptionCount() == 3)
        #expect(coordinator.status == .streaming)
        await coordinator.close()
    }

    private static func device() -> SimulatorDevice {
        SimulatorDevice(
            id: "DEVICE",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS",
            deviceTypeIdentifier: "phone",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
    }

    private static func snapshot() -> SimulatorAccessibilitySnapshot {
        SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "root",
                    role: "Application",
                    label: "Example",
                    value: nil,
                    frame: SimulatorRect(
                        x: 0,
                        y: 0,
                        width: 390,
                        height: 844
                    ),
                    isEnabled: true,
                    children: []
                ),
            ],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            )
        )
    }

    private static func maximumSnapshot() -> SimulatorAccessibilitySnapshot {
        let children = (0..<499).map { index in
            SimulatorAccessibilityNode(
                id: "element-\(index)",
                role: "Button",
                label: String(repeating: "Semantic element \(index) ", count: 8),
                value: "Value \(index)",
                frame: SimulatorRect(
                    x: Double(index % 10) * 39,
                    y: Double(index / 10) * 16,
                    width: 39,
                    height: 16
                ),
                isEnabled: true,
                children: []
            )
        }
        return SimulatorAccessibilitySnapshot(
            roots: [
                SimulatorAccessibilityNode(
                    id: "root",
                    role: "Application",
                    label: "Maximum semantic tree",
                    value: nil,
                    frame: SimulatorRect(
                        x: 0,
                        y: 0,
                        width: 390,
                        height: 844
                    ),
                    isEnabled: true,
                    children: children
                ),
            ],
            display: SimulatorDisplayMetadata(
                width: 1_170,
                height: 2_532,
                orientation: .portrait,
                scale: 3
            ),
            nodeCount: 500
        )
    }
}
