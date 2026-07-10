import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator location route lifecycle")
struct SimulatorControlServiceLocationLifecycleTests {
    @Test("A non-loop route completes, replays, and restores its first waypoint")
    func completionReplayAndRestore() async throws {
        let commands = LocationLifecycleCommandRunner()
        let sleeper = LocationLifecycleSleepGate()
        let service = SimulatorControlService(
            commands: commands,
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
            return activeRoute == nil && lifecycleTask == nil && token == nil
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
