@testable import CmuxCloud
import Foundation
import Testing

/// A refresh's owner clears `refreshTask` when it next runs on the hub. A caller waiting on the
/// same refresh can run first, and awaiting a finished task never gives up the actor, so a loop
/// that re-reads the field held the hub forever: one core at full speed, and every later hub call
/// (a team switch's discovery among them) waiting behind it until relaunch.
@Suite("Cloud hub: a caller waiting on a refresh")
struct CloudWireGuardHubRefreshWaitTests {
    /// Holds the refresh until the test has its waiter in place.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                defer { lock.unlock() }
                if isOpen { continuation.resume() } else { waiter = continuation }
            }
        }

        func open() {
            lock.lock()
            defer { lock.unlock() }
            isOpen = true
            waiter?.resume()
            waiter = nil
        }
    }

    /// Resumes once, with the first answer: a wedged hub can never answer, and its spinning task
    /// cannot be cancelled, so the deadline has to end the wait from outside it.
    final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func first(_ body: (Race) -> Void) async -> Bool {
            await withCheckedContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                body(self)
            }
        }

        func finish(_ value: Bool) {
            lock.lock()
            defer { lock.unlock() }
            continuation?.resume(returning: value)
            continuation = nil
        }
    }

    @Test("It ends with the refresh, and the hub still answers")
    func waiterEndsWithTheRefresh() async throws {
        let gate = Gate()
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-refresh-wait-\(UUID().uuidString.lowercased()).conf")
        try "[Peer]\nEndpoint = tun.example:51820\n".write(to: configURL, atomically: true, encoding: .utf8)
        let enrollment = CloudWireGuardHub.Enrollment(configPath: configURL.path, routes: ["10.75.105.0/24"])
        let hub = CloudWireGuardHub(configuration: .init(
            enroll: { enrollment },
            refreshEnrollment: {
                await gate.wait()
                return enrollment
            },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-refresh-wait-\(UUID().uuidString.lowercased()).sock"),
            spawner: CloudWireGuardHubDeadTunnelTests.Spawner(),
            waitUntilReady: { _ in },
            sleep: { _ in },
            restartBackoff: [],
            idleGrace: .seconds(3600),
            now: { ContinuousClock().now }
        ))
        _ = try await hub.acquire()

        // An address outside the enrolled routes starts a refresh, which the gate holds.
        let owner = Task { try await hub.readyRouting(anyOf: ["10.99.0.1"]) }
        try await Task.sleep(for: .milliseconds(200))
        // A silent route waits on that refresh.
        let waiter = Task { try await hub.refreshAfterUnansweredRoute() }
        try await Task.sleep(for: .milliseconds(200))
        gate.open()

        let finished = await Race().first { race in
            Task {
                _ = try? await owner.value
                _ = try? await waiter.value
                // The hub takes new work again.
                await hub.stop()
                race.finish(true)
            }
            Task {
                try? await Task.sleep(for: .seconds(10))
                race.finish(false)
            }
        }
        #expect(finished, "the waiter spun on the finished refresh and wedged the hub")
    }
}
