import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane startup cancellation")
@MainActor
struct SimulatorPaneCoordinatorCancellationTests {
    @Test("Canceled discovery leaves no failure and a later start retries")
    func canceledDiscoveryCanRetry() async {
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
        let firstStart = Task { @MainActor in
            await coordinator.start()
        }

        await client.waitForFirstDiscovery()
        firstStart.cancel()
        await firstStart.value

        #expect(coordinator.failure == nil)
        #expect(coordinator.status == .idle)
        #expect(!coordinator.started)

        await coordinator.start()

        #expect(await client.discoveryCount() == 2)
        #expect(coordinator.devices.map(\.id) == ["phone"])
        #expect(coordinator.selectedDeviceID == "phone")
        await coordinator.close()
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
