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

private actor LocationLifecycleCommandRunner: CommandRunning {
    private var recordedArguments: [[String]] = []

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        recordedArguments.append(arguments)
        return CommandResult(
            stdout: "",
            stderr: "",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }

    func arguments() -> [[String]] { recordedArguments }
}

private actor LocationLifecycleSleepGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var waiters: [Waiter] = []
    private var startCount = 0
    private var cancellationCount = 0
    private var startObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(for duration: Duration) async throws {
        _ = duration
        let id = UUID()
        startCount += 1
        resumeObservers(&startObservers, count: startCount)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func waitForStartCount(_ count: Int) async {
        guard startCount < count else { return }
        await withCheckedContinuation { startObservers.append((count, $0)) }
    }

    func waitForCancellationCount(_ count: Int) async {
        guard cancellationCount < count else { return }
        await withCheckedContinuation { cancellationObservers.append((count, $0)) }
    }

    private func cancel(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        cancellationCount += 1
        resumeObservers(&cancellationObservers, count: cancellationCount)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func resumeObservers(
        _ observers: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let ready = observers.filter { $0.0 <= count }
        observers.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }
}
