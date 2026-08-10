import CmuxSimulator
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator pane location lifecycle")
@MainActor
struct SimulatorPaneCoordinatorLocationLifecycleTests {
    @Test("Switching from A to B restores A before activating B")
    func deviceSwitchStopsRouteFirst() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A"), Self.device("B")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await eventually { await client.operations().contains("activate:A") }
        await coordinator.startLocationRoute(Self.route())

        coordinator.selectDevice(id: "B")
        await eventually { await client.operations().contains("activate:B") }

        let operations = await client.operations()
        let stopIndex = operations.firstIndex(of: "stop:A")
        let activationIndex = operations.firstIndex(of: "activate:B")
        #expect(stopIndex != nil)
        #expect(activationIndex != nil)
        if let stopIndex, let activationIndex { #expect(stopIndex < activationIndex) }
        await coordinator.close()
    }

    @Test("A route that commits during device selection is stopped before activation")
    func pendingRouteCommitIsReclaimedDuringDeviceSwitch() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A"), Self.device("B")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await eventually { await client.operations().contains("activate:A") }
        await client.blockNextStart()

        coordinator.scheduleControlAction("location-route") {
            await $0.startLocationRoute(Self.route())
        }
        await client.waitUntilStartIsPending()
        coordinator.selectDevice(id: "B")
        await client.resumePendingStart()
        await eventually { await client.operations().contains("activate:B") }

        let operations = await client.operations()
        let startIndex = operations.firstIndex(of: "start:A")
        let stopIndex = operations.firstIndex(of: "stop:A")
        let activationIndex = operations.firstIndex(of: "activate:B")
        #expect(startIndex != nil)
        #expect(stopIndex != nil)
        #expect(activationIndex != nil)
        if let startIndex, let stopIndex, let activationIndex {
            #expect(startIndex < stopIndex)
            #expect(stopIndex < activationIndex)
        }
        #expect(coordinator.locationRouteDeviceID == nil)
        await coordinator.close()
    }

    @Test("Close and shutdown restore a route before ending their device lifecycle")
    func closeAndShutdownStopRouteFirst() async {
        let closeClient = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let closeCoordinator = SimulatorPaneCoordinator(client: closeClient)
        await closeCoordinator.start()
        await eventually { await closeClient.operations().contains("activate:A") }
        await closeCoordinator.startLocationRoute(Self.route())

        await closeCoordinator.close()

        let closeOperations = await closeClient.operations()
        let closeStopIndex = closeOperations.firstIndex(of: "stop:A")
        let closeIndex = closeOperations.firstIndex(of: "close")
        #expect(closeStopIndex != nil)
        #expect(closeIndex != nil)
        if let closeStopIndex, let closeIndex { #expect(closeStopIndex < closeIndex) }

        let shutdownClient = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let shutdownCoordinator = SimulatorPaneCoordinator(client: shutdownClient)
        await shutdownCoordinator.start()
        await eventually { await shutdownClient.operations().contains("activate:A") }
        await shutdownCoordinator.startLocationRoute(Self.route())

        shutdownCoordinator.shutdownSelectedDevice()
        await eventually { await shutdownClient.operations().contains("shutdown:A") }

        let shutdownOperations = await shutdownClient.operations()
        let shutdownStopIndex = shutdownOperations.firstIndex(of: "stop:A")
        let shutdownIndex = shutdownOperations.firstIndex(of: "shutdown:A")
        #expect(shutdownStopIndex != nil)
        #expect(shutdownIndex != nil)
        if let shutdownStopIndex, let shutdownIndex { #expect(shutdownStopIndex < shutdownIndex) }
        await shutdownCoordinator.close()
    }

    @Test("Device loss and worker crash restore the active route")
    func lossAndCrashStopRoute() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.startLocationRoute(Self.route())

        await client.emit(.message(.status(.deviceUnavailable)))
        await eventually { await client.operations().filter { $0 == "stop:A" }.count == 1 }
        #expect(!coordinator.locationRouteIsActive)

        await coordinator.startLocationRoute(Self.route())
        await client.emit(.workerStopped)
        await eventually { await client.operations().filter { $0 == "stop:A" }.count == 2 }
        #expect(!coordinator.locationRouteIsActive)
        await coordinator.close()
    }

    @Test("Failed teardown retains the route identity for retry and reports the failure")
    func failedTeardownRemainsPending() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.startLocationRoute(Self.route())
        await client.failNextStops(3)

        await client.emit(.message(.status(.deviceUnavailable)))
        await eventually { coordinator.failure?.code == "injected_stop_failure" }

        #expect(coordinator.locationRouteDeviceID == "A")
        #expect(await client.operations().filter { $0 == "stop:A" }.count == 3)

        await coordinator.close()
        #expect(await client.operations().filter { $0 == "stop:A" }.count == 4)
        #expect(coordinator.locationRouteDeviceID == nil)
    }

    @Test("Discovery restores a removed device route before failing closed")
    func discoveryLossStopsRoute() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A"), Self.device("B")])
        let coordinator = SimulatorPaneCoordinator(client: client)
        await coordinator.start()
        await coordinator.startLocationRoute(Self.route())
        await client.setDevices([Self.device("B")])

        await coordinator.reloadDevices()

        #expect(coordinator.selectedDeviceID == nil)
        #expect(coordinator.requiresExplicitDeviceSelection)
        #expect(coordinator.failure?.code == "simulator_saved_device_unavailable")
        #expect(await client.operations().contains("stop:A"))
        #expect(!coordinator.locationRouteIsActive)
        await coordinator.close()
    }

    @Test("A non-loop route completes inactive and can replay")
    func naturalCompletionAndReplay() async {
        let client = LocationLifecyclePaneClient(devices: [Self.device("A")])
        let sleeper = LocationLifecyclePaneSleeper()
        let coordinator = SimulatorPaneCoordinator(
            client: client,
            webInspectorSleeper: ImmediateLocationLifecyclePaneSleeper(),
            locationRouteSleeper: sleeper
        )
        await coordinator.start()

        await coordinator.startLocationRoute(Self.route())
        await sleeper.waitForStartCount(1)
        #expect(coordinator.locationRouteIsActive)

        await sleeper.advance()
        await eventually { !coordinator.locationRouteIsActive }
        #expect(!coordinator.locationRouteIsPaused)

        await coordinator.startLocationRoute(Self.route())
        await sleeper.waitForStartCount(2)
        #expect(coordinator.locationRouteIsActive)
        #expect(await client.operations().filter { $0 == "start:A" }.count == 2)

        await coordinator.close()
        await sleeper.waitForCancellationCount(1)
        #expect(await client.operations().contains("stop:A"))
    }

    private static func route() -> SimulatorLocationRoute {
        SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 37.7, longitude: -122.4),
                SimulatorLocationCoordinate(latitude: 37.71, longitude: -122.39),
            ],
            speed: 3
        )
    }

    private static func device(_ id: String) -> SimulatorDevice {
        SimulatorDevice(
            id: id,
            name: id,
            runtimeIdentifier: "runtime",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "phone",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )
    }

    private func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async {
        for _ in 0..<300 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}
