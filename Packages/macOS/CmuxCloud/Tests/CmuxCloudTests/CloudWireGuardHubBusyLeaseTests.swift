import CmuxCloud
import Foundation
import Testing

/// Every build and tunnel role on one Mac shares the server's access lease.
/// A busy answer is someone else's progress, so the hub waits for it instead
/// of failing the connection after a few restart attempts.
@Suite("Cloud hub waits for a busy Mac access lease")
struct CloudWireGuardHubBusyLeaseTests {
    final class Process: CloudWireGuardHubProcess, @unchecked Sendable {
        private var handler: (@Sendable (Int32) -> Void)?
        var isRunning = true
        var exitStatus: Int32?
        let outputTail = "test"

        func terminate() {
            isRunning = false
            exitStatus = 0
            handler?(0)
        }

        func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
            self.handler = handler
        }
    }

    final class Spawner: CloudWireGuardHubSpawning, @unchecked Sendable {
        private(set) var spawned = 0

        func spawn(executable: URL, arguments: [String]) throws -> any CloudWireGuardHubProcess {
            spawned += 1
            return Process()
        }
    }

    actor Recorder {
        private(set) var enrollments = 0
        private(set) var sleeps: [Duration] = []

        func enroll() -> Int {
            enrollments += 1
            return enrollments
        }

        func slept(_ duration: Duration) {
            sleeps.append(duration)
        }
    }

    @Test("More busy answers than the restart table allows still end in a running hub")
    func busyLeaseDoesNotSpendRestartAttempts() async throws {
        let recorder = Recorder()
        let spawner = Spawner()
        let hub = CloudWireGuardHub(configuration: .init(
            enroll: {
                if await recorder.enroll() <= 4 {
                    throw VMClientError.httpStatus(
                        409,
                        #"{"error":"vm_access_grant_busy","retryable":true,"retryAfterSeconds":3}"#
                    )
                }
                return CloudWireGuardHub.Enrollment(configPath: "/tmp/busy-lease.conf", routes: ["10.0.0.0/8"])
            },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-busy-lease-\(UUID().uuidString.lowercased()).sock"),
            spawner: spawner,
            waitUntilReady: { _ in },
            sleep: { duration in await recorder.slept(duration) },
            restartBackoff: [.seconds(1)],
            idleGrace: .seconds(3600)
        ))

        let ready = try await hub.prewarm()

        #expect(ready.routes == ["10.0.0.0/8"])
        #expect(await recorder.enrollments == 5)
        #expect(await recorder.sleeps == Array(repeating: .seconds(3), count: 4))
        #expect(spawner.spawned == 1)
        await hub.stop()
    }

    @Test("A busy lease that outlasts the budget fails with the server's answer")
    func busyLeaseIsBounded() async throws {
        let recorder = Recorder()
        let hub = CloudWireGuardHub(configuration: .init(
            enroll: {
                _ = await recorder.enroll()
                throw VMClientError.httpStatus(
                    409,
                    #"{"error":"vm_access_grant_busy","retryable":true,"retryAfterSeconds":30}"#
                )
            },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-busy-lease-\(UUID().uuidString.lowercased()).sock"),
            spawner: Spawner(),
            waitUntilReady: { _ in },
            sleep: { duration in await recorder.slept(duration) },
            restartBackoff: [],
            idleGrace: .seconds(3600)
        ))

        await #expect(throws: VMClientError.self) { _ = try await hub.prewarm() }
        // 90 seconds of budget at 30 seconds a wait: three waits, four asks.
        #expect(await recorder.sleeps == Array(repeating: .seconds(30), count: 3))
        #expect(await recorder.enrollments == 4)
        await hub.stop()
    }
}
