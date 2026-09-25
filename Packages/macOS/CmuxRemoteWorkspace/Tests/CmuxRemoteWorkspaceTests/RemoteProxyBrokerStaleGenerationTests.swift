import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteProxyBroker stale tunnel generations", .serialized)
struct RemoteProxyBrokerStaleGenerationTests {
    private func makeConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "test@example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
    }

    @Test("fatal callback from a replaced tunnel cannot stop its successor")
    func staleFatalCallbackCannotStopSuccessor() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration()

        let leaseA = broker.acquire(configuration: configuration, remotePath: "/old/path") { _ in }
        defer { leaseA.release() }
        let staleFatalError = try #require(provider.fatalErrorCallback(at: 0))

        let leaseB = broker.acquire(configuration: configuration, remotePath: "/new/path") { _ in }
        defer { leaseB.release() }
        #expect(provider.tunnels.count == 2)
        let successor = try #require(provider.tunnels.last)
        #expect(successor.remotePath == "/new/path")
        #expect(successor.stopCount == 0)

        staleFatalError("stale failure from replaced tunnel")

        // This synchronous broker call is submitted after the stale callback's
        // queue hop, so it deterministically observes the callback's effect.
        let sessions = try broker.listPTY(configuration: configuration)
        #expect(sessions.first?["session_id"] as? String == "s-1")
        #expect(successor.stopCount == 0)
        #expect(provider.tunnels.count == 2)
    }
}
