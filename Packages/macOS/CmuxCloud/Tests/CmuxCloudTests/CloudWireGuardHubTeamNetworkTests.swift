import CmuxCloud
import Foundation
import Testing

@Suite("team network hub refresh")
struct CloudWireGuardHubTeamNetworkTests {
    final class Process: CloudWireGuardHubProcess, @unchecked Sendable {
        private(set) var terminateCount = 0
        private var handler: (@Sendable (Int32) -> Void)?
        var isRunning = true
        var exitStatus: Int32?
        let outputTail = "test"

        func terminate() {
            terminateCount += 1
            isRunning = false
            exitStatus = 0
            handler?(0)
        }

        func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
            self.handler = handler
        }
    }

    final class Spawner: CloudWireGuardHubSpawning, @unchecked Sendable {
        private(set) var processes: [Process] = []

        func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess {
            let process = Process()
            processes.append(process)
            return process
        }
    }

    final class ClockBox: @unchecked Sendable {
        var value = ContinuousClock().now
    }

    final class StateBox: @unchecked Sendable {
        var routes: [String]
        var refreshes = 0

        init(routes: [String]) { self.routes = routes }
    }

    actor SleepRecorder {
        private(set) var durations: [Duration] = []
        private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

        func sleep(_ duration: Duration) async throws {
            durations.append(duration)
            let ready = observers.filter { durations.count >= $0.0 }
            observers.removeAll { durations.count >= $0.0 }
            for (_, observer) in ready { observer.resume() }
            try await Task.sleep(for: duration)
        }

        func waitForCount(_ count: Int) async {
            if durations.count >= count { return }
            await withCheckedContinuation { observers.append((count, $0)) }
        }
    }

    actor RefreshGate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []
        private var started = false

        func wait() async {
            started = true
            let pending = observers
            observers.removeAll()
            for observer in pending { observer.resume() }
            await withCheckedContinuation { waiter = $0 }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { observers.append($0) }
        }

        func resume() {
            waiter?.resume()
            waiter = nil
        }
    }

    private func makeHub(
        routes: @escaping @Sendable () -> [String],
        refresh: @escaping @Sendable () async throws -> CloudWireGuardHub.Enrollment,
        clock: ClockBox,
        spawner: Spawner,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) }
    ) -> CloudWireGuardHub {
        CloudWireGuardHub(configuration: .init(
            enroll: { CloudWireGuardHub.Enrollment(configPath: "/tmp/test.conf", routes: routes()) },
            refreshEnrollment: refresh,
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: URL(fileURLWithPath: "/tmp/test-hub.sock"),
            spawner: spawner,
            waitUntilReady: { _ in },
            sleep: sleep,
            restartBackoff: [],
            idleGrace: .seconds(3600),
            now: { clock.value }
        ))
    }

    @Test("routed host does not refresh")
    func routedHostSkipsRefresh() async throws {
        let clock = ClockBox()
        let spawner = Spawner()
        let state = StateBox(routes: ["10.20.0.0/24"])
        let hub = makeHub(routes: { state.routes }, refresh: {
            state.refreshes += 1
            return .init(configPath: "/tmp/test.conf", routes: ["10.30.0.0/24"])
        }, clock: clock, spawner: spawner)
        let first = try await hub.readyRouting(anyOf: ["10.20.0.4"])
        let second = try await hub.readyRouting(anyOf: ["10.20.0.4"])
        #expect(first == second)
        #expect(state.refreshes == 0)
    }

    @Test("unrouted host refreshes and restarts while retaining leases")
    func unroutedHostRestarts() async throws {
        let clock = ClockBox()
        let spawner = Spawner()
        let state = StateBox(routes: ["10.20.0.0/24"])
        let hub = makeHub(routes: { state.routes }, refresh: {
            state.refreshes += 1
            state.routes = ["10.30.0.0/24"]
            return .init(configPath: "/tmp/test.conf", routes: state.routes)
        }, clock: clock, spawner: spawner)
        let claim = try await hub.acquire()
        let before = spawner.processes[0]
        let ready = try await hub.readyRouting(anyOf: ["10.30.0.4"])
        #expect(state.refreshes == 1)
        #expect(before.terminateCount > 0)
        #expect(spawner.processes.count == 2)
        #expect(ready.routes == ["10.30.0.0/24"])
        #expect((await hub.status()).leases == 1)
        await hub.release(claim.lease)
    }

    @Test("identical routes and throttled calls do not restart")
    func identicalAndThrottled() async throws {
        let clock = ClockBox()
        let spawner = Spawner()
        let state = StateBox(routes: ["10.20.0.0/24"])
        let hub = makeHub(routes: { state.routes }, refresh: {
            state.refreshes += 1
            return .init(configPath: "/tmp/test.conf", routes: state.routes)
        }, clock: clock, spawner: spawner)
        _ = try await hub.readyRouting(anyOf: ["10.30.0.4"])
        let firstCount = spawner.processes.count
        _ = try await hub.readyRouting(anyOf: ["10.30.0.4"])
        #expect(state.refreshes == 1)
        #expect(spawner.processes.count == firstCount)
        clock.value = clock.value.advanced(by: .seconds(16))
        _ = try await hub.readyRouting(anyOf: ["10.30.0.4"])
        #expect(state.refreshes == 2)
    }

    @Test("unclaimed refresh restart schedules idle stop")
    func unclaimedRestartSchedulesIdleStop() async throws {
        let clock = ClockBox()
        let recorder = SleepRecorder()
        let spawner = Spawner()
        let state = StateBox(routes: ["10.20.0.0/24"])
        let hub = makeHub(routes: { state.routes }, refresh: {
            state.routes = ["10.30.0.0/24"]
            return .init(configPath: "/tmp/test.conf", routes: state.routes)
        }, clock: clock, spawner: spawner, sleep: recorder.sleep)
        _ = try await hub.readyRouting(anyOf: ["10.20.0.4"])
        await recorder.waitForCount(1)
        _ = try await hub.readyRouting(anyOf: ["10.30.0.4"])
        await recorder.waitForCount(2)
        #expect(await recorder.durations == [.seconds(3600), .seconds(3600)])
        #expect(spawner.processes.count == 2)
        await hub.stop()
    }

    @Test("stop during refresh prevents respawn")
    func stopDuringRefreshPreventsRespawn() async throws {
        let clock = ClockBox()
        let spawner = Spawner()
        let gate = RefreshGate()
        let state = StateBox(routes: ["10.20.0.0/24"])
        let hub = makeHub(routes: { state.routes }, refresh: {
            await gate.wait()
            state.routes = ["10.30.0.0/24"]
            return .init(configPath: "/tmp/test.conf", routes: state.routes)
        }, clock: clock, spawner: spawner)
        let task = Task { try await hub.readyRouting(anyOf: ["10.30.0.4"]) }
        await gate.waitUntilStarted()
        await hub.stop()
        await gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(spawner.processes.count == 1)
        #expect((await hub.status()).running == false)
    }

    @Test("concurrent callers share refresh and failures are throttled")
    func singleFlightAndFailureThrottle() async throws {
        let clock = ClockBox()
        let spawner = Spawner()
        let state = StateBox(routes: ["10.20.0.0/24"])
        let hub = makeHub(routes: { state.routes }, refresh: {
            state.refreshes += 1
            try await Task.sleep(for: .milliseconds(1))
            throw TestError.failed
        }, clock: clock, spawner: spawner)
        let first = Task { try await hub.readyRouting(anyOf: ["10.30.0.4"]) }
        let second = Task { try await hub.readyRouting(anyOf: ["10.30.0.5"]) }
        await #expect(throws: TestError.self) { try await first.value }
        _ = try? await second.value
        #expect(state.refreshes == 1)
        _ = try await hub.readyRouting(anyOf: ["10.30.0.6"])
        #expect(state.refreshes == 1)
        clock.value = clock.value.advanced(by: .seconds(16))
        await #expect(throws: TestError.self) {
            try await hub.readyRouting(anyOf: ["10.30.0.6"])
        }
        #expect(state.refreshes == 2)
        await hub.stop()
    }

    enum TestError: Error { case failed }
}
