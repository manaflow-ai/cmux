@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Testing

/// The pane's endpoint provider must follow a machine reconnect, which replaces the Cloud ticket.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct AgentTabRemoteEndpointTests {
    @Test func reconnectRetriesWithTheReplacementEndpoint() async throws {
        let daemon = DaemonService(machineID: "cloud:fixture")
        daemon.start(remote: { throw DaemonError.notConnected })
        // Keep the endpoint provider but cancel the background daemon connection before it runs.
        daemon.shutdownConnection()
        let endpoint = AgentTabRemoteHost.endpoint(on: daemon)

        let recovered = try await AgentSessionAttachClient.retrying({ _ in try await endpoint() }, reconnect: {
            await MainActor.run {
                daemon.start(remote: { "/fixture/reconnected-ticket.sock" })
                daemon.shutdownConnection()
            }
            return true
        })

        #expect(recovered.socketPath == "/fixture/reconnected-ticket.sock")
    }
}
