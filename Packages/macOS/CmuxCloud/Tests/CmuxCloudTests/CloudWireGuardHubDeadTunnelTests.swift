@testable import CmuxCloud
import Foundation
import Testing

/// A hub whose tunnel peer was deleted on the server still answers the SOCKS
/// greeting, but no CONNECT to a routed machine is ever answered. Nothing used
/// to re-enroll it, so every machine showed a handshake timeout until relaunch.
@Suite("Cloud hub recovers a dead tunnel")
struct CloudWireGuardHubDeadTunnelTests {
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

    /// The server's side of re-enrollment: what config it writes, or a refusal.
    final class Server: @unchecked Sendable {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dead-tunnel-\(UUID().uuidString.lowercased()).conf")
        var nextConfig = "[Peer]\nEndpoint = tun-old.example:51820\n"
        var refusal: VMClientError?
        private(set) var enrollments = 0

        /// Like production, a start reuses the config already on disk.
        func written() -> CloudWireGuardHub.Enrollment? {
            FileManager.default.fileExists(atPath: configURL.path)
                ? .init(configPath: configURL.path, routes: ["10.75.105.0/24"]) : nil
        }

        func enroll() throws -> CloudWireGuardHub.Enrollment {
            enrollments += 1
            if let refusal { throw refusal }
            try nextConfig.write(to: configURL, atomically: true, encoding: .utf8)
            return .init(configPath: configURL.path, routes: ["10.75.105.0/24"])
        }
    }

    final class ClockBox: @unchecked Sendable {
        var now = ContinuousClock().now
    }

    private func makeHub(server: Server, spawner: Spawner, clock: ClockBox) -> CloudWireGuardHub {
        CloudWireGuardHub(configuration: .init(
            enroll: { try server.written() ?? server.enroll() },
            refreshEnrollment: { try server.enroll() },
            clientURL: URL(fileURLWithPath: "/usr/bin/true"),
            socketURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-dead-tunnel-\(UUID().uuidString.lowercased()).sock"),
            spawner: spawner,
            waitUntilReady: { _ in },
            sleep: { _ in },
            restartBackoff: [],
            idleGrace: .seconds(3600),
            now: { clock.now }
        ))
    }

    @Test("A recreated peer restarts the hub on its new config")
    func newConfigRestartsTheHub() async throws {
        let server = Server()
        let spawner = Spawner()
        let hub = makeHub(server: server, spawner: spawner, clock: ClockBox())
        _ = try await hub.acquire()
        // The server recreated the deleted peer: same routes, new endpoint.
        server.nextConfig = "[Peer]\nEndpoint = tun-new.example:51820\n"

        let refreshed = try await hub.refreshAfterUnansweredRoute()

        #expect(refreshed?.routes == ["10.75.105.0/24"])
        #expect(server.enrollments == 2)
        #expect(spawner.spawned == 2)
        await hub.stop()
    }

    @Test("An unchanged config never disrupts a working hub, and asking again is throttled")
    func unchangedConfigKeepsTheHub() async throws {
        let server = Server()
        let spawner = Spawner()
        let clock = ClockBox()
        let hub = makeHub(server: server, spawner: spawner, clock: clock)
        _ = try await hub.acquire()

        #expect(try await hub.refreshAfterUnansweredRoute() == nil)
        #expect(spawner.spawned == 1)
        #expect(server.enrollments == 2)
        // Within the minute, a second silent route does not ask the server again.
        clock.now += .seconds(30)
        #expect(try await hub.refreshAfterUnansweredRoute() == nil)
        #expect(server.enrollments == 2)
        clock.now += .seconds(31)
        _ = try await hub.refreshAfterUnansweredRoute()
        #expect(server.enrollments == 3)
        await hub.stop()
    }

    @Test("A revoked sign-in comes back as the server's answer")
    func refusalPropagates() async throws {
        let server = Server()
        let hub = makeHub(server: server, spawner: Spawner(), clock: ClockBox())
        _ = try await hub.acquire()
        server.refusal = .httpStatus(403, #"{"error":"vm_access_revoked","phase":"network"}"#)

        do {
            _ = try await hub.refreshAfterUnansweredRoute()
            Issue.record("a refused re-enrollment cannot claim recovery")
        } catch let error as VMClientError {
            #expect(CloudMachineAccessLoss(error: error) == .signInRevoked)
        }
        await hub.stop()
    }

    @Test("A silent deadline names the whole budget, not one attempt's cap")
    func deadlineNamesTheBudget() async {
        do {
            _ = try await CloudHubConnector.hedged(
                candidates: 2,
                fallbackDelay: .milliseconds(5),
                redialInterval: .milliseconds(20),
                maxRedials: 1_000,
                slowPhase: CloudHubSlowRedialPhase(after: .milliseconds(40), interval: .milliseconds(40)),
                timeout: .milliseconds(300),
                clock: ContinuousClock(),
                attempt: { _ -> Int in
                    try await Task.sleep(for: .milliseconds(30))
                    throw CloudPortForwardRelay.RelayError.handshakeTimedOut(.milliseconds(30))
                },
                discard: { _ in }
            )
            Issue.record("nothing answered, so the connect must fail")
        } catch {
            #expect(error.localizedDescription.contains("0.3 seconds"))
        }
    }
}
