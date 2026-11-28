import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp
@testable import CmuxNextDaemonService

/// startup-tti: a restored terminal's attachment takes the first connection's socket as soon as the prestart's
/// handshake kept the daemon (`DaemonService.launchEndpoint`), read off the main actor, instead of waiting for the
/// main actor's `didConnect`, which ran 300+ ms later behind the launch window's build (warm launch marks:
/// `daemon.handshake_end` 190 ms, `daemon_connected` 523 ms).
@MainActor
struct DaemonAttachEndpointTests {
    @Test func anAttachmentTakesTheLaunchSocketWithoutTheMainActor() async throws {
        let daemon = DaemonService()
        let socket = DaemonEndpoint(socketPath: "/tmp/cmux-attach-endpoint-\(UUID().uuidString).sock")
        daemon.launchEndpoint.set(socket)
        // Off the main actor, as the attach driver's detached task calls it.
        let read = try await Task.detached { try await daemon.attachEndpoint() }.value
        #expect(read.socketPath == socket.socketPath)
    }

    @Test func aPolicyBlockStillRefusesTheLaunchSocket() async {
        let daemon = DaemonService()
        daemon.launchEndpoint.set(DaemonEndpoint(socketPath: "/tmp/cmux-attach-endpoint-blocked.sock"))
        daemon.policyBlock.set(true)
        await #expect(throws: DaemonError.self) { try await daemon.attachEndpoint() }
    }

    @Test func withoutALaunchSocketAnAttachmentAsksTheService() async {
        // Never started: no connection, no launch socket, so the service's own answer (not connected).
        await #expect(throws: DaemonError.self) { try await DaemonService().attachEndpoint() }
    }
}
