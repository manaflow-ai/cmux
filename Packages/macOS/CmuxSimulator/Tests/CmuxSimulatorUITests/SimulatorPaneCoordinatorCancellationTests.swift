import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane startup cancellation")
@MainActor
struct SimulatorPaneCoordinatorCancellationTests {
    @Test("A canceled startup waiter does not cancel pane-owned discovery")
    func canceledStartupWaiterDoesNotCancelDiscovery() async {
        let device = SimulatorDevice(
            id: "phone",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone-type",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = CancellableDiscoveryPaneClient(device: device)
        let coordinator = SimulatorPaneCoordinator(client: client)
        let paneStart = Task { @MainActor in
            await coordinator.start()
        }

        await client.waitForFirstDiscovery()
        let socketWaiter = Task { @MainActor in
            await coordinator.start()
        }
        socketWaiter.cancel()
        await socketWaiter.value

        #expect(coordinator.failure == nil)
        #expect(coordinator.started)
        #expect(await client.discoveryCount() == 1)

        await coordinator.close()
        await paneStart.value
        #expect(coordinator.status == .idle)
    }

    @Test("Cancelled explicit selection stops its activation generation")
    func cancelledSelectionStopsActivation() async {
        let device = SimulatorDevice(
            id: "phone",
            name: "iPhone",
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone-type",
            family: .iPhone,
            state: .shutdown,
            isAvailable: true,
            lastBootedAt: nil
        )
        let client = SimulatorPaneClientSpy(devices: [device], delaysActivation: true)
        let coordinator = SimulatorPaneCoordinator(client: client)
        let selection = Task { @MainActor in
            try await coordinator.selectDeviceAndWait(id: device.id)
        }
        for _ in 0..<100 {
            if await client.activations().count == 1 { break }
            await Task.yield()
        }

        selection.cancel()
        do {
            try await selection.value
            Issue.record("Expected selection cancellation")
        } catch is CancellationError {}
        catch { Issue.record("Unexpected error: \(error)") }

        #expect(await client.activationCancellationCount() == 1)
        #expect(coordinator.status == .idle)
        await coordinator.close()
    }
}
