import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator location route lifecycle")
struct SimulatorControlServiceLocationLifecycleTests {
    @Test("Same-device location mutations remain serialized")
    func sameDeviceMutationsAreSerialized() async throws {
        let commands = BlockingLocationCommandRunner()
        let service = SimulatorControlService(
            commands: commands,
            locationOwnershipScope: SimulatorLocationOwnershipScope()
        )
        let deviceID = UUID().uuidString
        let first = Task {
            try await service.setLocation(
                deviceID: deviceID,
                coordinate: SimulatorLocationCoordinate(latitude: 1, longitude: 2)
            )
        }
        await commands.waitForInvocationCount(1)
        let second = Task { try await service.clearLocation(deviceID: deviceID) }

        for _ in 0..<100 { await Task.yield() }
        #expect(await commands.arguments().count == 1)

        await commands.releaseFirstCommand()
        try await first.value
        try await second.value

        #expect(await commands.arguments() == [
            ["simctl", "location", deviceID, "set", "1.0,2.0"],
            ["simctl", "location", deviceID, "clear"],
        ])
    }

    @Test("A non-loop route completes, replays, and restores its first waypoint")
    func completionReplayAndRestore() async throws {
        let commands = LocationLifecycleCommandRunner()
        let sleeper = LocationLifecycleSleepGate()
        let service = SimulatorControlService(
            commands: commands,
            locationOwnershipScope: SimulatorLocationOwnershipScope(),
            routeSleep: { duration in try await sleeper.sleep(for: duration) }
        )
        let route = Self.route()

        try await service.startLocationRoute(deviceID: "DEVICE", route: route)
        await sleeper.waitForStartCount(1)
        #expect(await service.activeLocationRoutes["DEVICE"] != nil)

        await sleeper.advance()
        await eventually {
            let activeRoute = await service.activeLocationRoutes["DEVICE"]
            let lifecycleTask = await service.locationLifecycleTasks["DEVICE"]
            let token = await service.locationRouteTokens["DEVICE"]
            return activeRoute == nil && lifecycleTask == nil && token != nil
        }
        #expect(await service.locationRouteInitialCoordinates["DEVICE"] == route.waypoints[0])

        try await service.startLocationRoute(deviceID: "DEVICE", route: route)
        await sleeper.waitForStartCount(2)
        #expect(await service.activeLocationRoutes["DEVICE"] != nil)

        try await service.stopLocationRoute(deviceID: "DEVICE")
        await sleeper.waitForCancellationCount(1)

        let arguments = await commands.arguments()
        #expect(arguments.filter { $0.prefix(4) == ["simctl", "location", "DEVICE", "start"] }.count == 2)
        #expect(arguments.suffix(2) == [
            ["simctl", "location", "DEVICE", "clear"],
            ["simctl", "location", "DEVICE", "set", "37.7,-122.4"],
        ])
        #expect(await service.activeLocationRoutes["DEVICE"] == nil)
        #expect(await service.locationRouteInitialCoordinates["DEVICE"] == nil)
    }

    @Test(
        "Failed pause and stop commands preserve their running route lifecycle",
        arguments: [1, 2]
    )
    func failedPauseAndStopPreserveLifecycle(failureInvocationIndex: Int) async throws {
        for operation in [LocationRouteMutation.pause, .stop] {
            let commands = LocationLifecycleCommandRunner(
                failureInvocationIndices: [failureInvocationIndex]
            )
            let service = SimulatorControlService(
                commands: commands,
                locationOwnershipScope: SimulatorLocationOwnershipScope()
            )
            let route = Self.route()
            try await service.startLocationRoute(deviceID: "DEVICE", route: route)

            do {
                switch operation {
                case .pause:
                    try await service.pauseLocationRoute(deviceID: "DEVICE")
                case .stop:
                    try await service.stopLocationRoute(deviceID: "DEVICE")
                }
                Issue.record("Expected the injected location command failure")
            } catch {}

            guard case .running? = await service.activeLocationRoutes["DEVICE"] else {
                Issue.record("The failed \(operation) discarded the running route")
                continue
            }
            #expect(await service.locationRouteTokens["DEVICE"] != nil)
            #expect(await service.locationLifecycleTasks["DEVICE"] != nil)
            let arguments = await commands.arguments()
            if failureInvocationIndex == 2 {
                #expect(arguments.last?.prefix(4) == ["simctl", "location", "DEVICE", "start"])
            } else {
                #expect(arguments.count == 2)
            }
        }
    }

    @Test("A newer client prevents an older looping route from replaying")
    func newerClientOwnsLocationMutation() async throws {
        let deviceID = UUID().uuidString
        let scope = SimulatorLocationOwnershipScope()
        let oldCommands = LocationLifecycleCommandRunner()
        let oldSleeper = LocationLifecycleSleepGate()
        let oldService = SimulatorControlService(
            commands: oldCommands,
            locationOwnershipScope: scope,
            routeSleep: { duration in try await oldSleeper.sleep(for: duration) }
        )
        let newCommands = LocationLifecycleCommandRunner()
        let newService = SimulatorControlService(
            commands: newCommands,
            locationOwnershipScope: scope
        )
        let baseRoute = Self.route()
        let loop = SimulatorLocationRoute(
            waypoints: baseRoute.waypoints,
            speed: baseRoute.speed,
            updateDistance: baseRoute.updateDistance,
            updateInterval: baseRoute.updateInterval,
            loops: true
        )

        try await oldService.startLocationRoute(deviceID: deviceID, route: loop)
        await oldSleeper.waitForStartCount(1)
        try await newService.setLocation(
            deviceID: deviceID,
            coordinate: SimulatorLocationCoordinate(latitude: 40, longitude: -73)
        )
        await oldSleeper.advance()
        await eventually {
            await oldService.activeLocationRoutes[deviceID] == nil
        }

        #expect(await oldCommands.arguments().count == 1)
        #expect(await newCommands.arguments() == [
            ["simctl", "location", deviceID, "set", "40.0,-73.0"],
        ])
        #expect(await oldService.activeLocationRoutes[deviceID] == nil)
        #expect(await oldService.locationRouteInitialCoordinates[deviceID] == nil)
        #expect(await oldService.locationRouteTokens[deviceID] == nil)
    }

    @Test("Losing route ownership reports failure and clears stale local state")
    func lostOwnershipFailsPause() async throws {
        let deviceID = UUID().uuidString
        let scope = SimulatorLocationOwnershipScope()
        let oldService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: scope
        )
        let newService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: scope
        )

        try await oldService.startLocationRoute(deviceID: deviceID, route: Self.route())
        try await newService.setLocation(
            deviceID: deviceID,
            coordinate: SimulatorLocationCoordinate(latitude: 40, longitude: -73)
        )

        do {
            try await oldService.pauseLocationRoute(deviceID: deviceID)
            Issue.record("Expected lost location ownership to fail explicitly")
        } catch let error as SimulatorControlError {
            #expect(error.code == "location_route_ownership_lost")
        }
        #expect(await oldService.activeLocationRoutes[deviceID] == nil)
        #expect(await oldService.locationRouteInitialCoordinates[deviceID] == nil)
        #expect(await oldService.locationRouteTokens[deviceID] == nil)
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

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Condition did not become true")
    }
}

private enum LocationRouteMutation: CustomStringConvertible {
    case pause
    case stop

    var description: String {
        switch self {
        case .pause: "pause"
        case .stop: "stop"
        }
    }
}
