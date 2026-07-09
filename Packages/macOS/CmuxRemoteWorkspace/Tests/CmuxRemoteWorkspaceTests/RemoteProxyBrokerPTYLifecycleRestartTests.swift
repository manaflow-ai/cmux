import CmuxCore
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemoteProxyBroker PTY lifecycle restart", .serialized)
struct RemoteProxyBrokerPTYLifecycleRestartTests {
    @Test("intentional-close lifecycle survives a failed automatic tunnel replacement")
    func intentionalCloseSurvivesTunnelReplacement() throws {
        let provider = FakeTunnelProvider()
        let clock = ManualRetryClock()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: clock)
        let configuration = makeConfiguration()
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        _ = try broker.startPTYBridge(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation",
            attachmentID: "surface",
            command: nil,
            requireExisting: true
        )
        try broker.closePTY(configuration: configuration, sessionID: "session")
        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation"
        ) == .intentionallyClosed)

        provider.failNextStarts(1)
        let fatalError = try #require(provider.fatalErrorCallback(at: 0))
        fatalError("transport died")
        #expect(clock.waitForSleeps(1))
        clock.fireOldestSleep()
        #expect(clock.waitForSleeps(2))
        clock.fireOldestSleep()
        let deadline = Date().addingTimeInterval(5.0)
        while provider.tunnels.count < 3 && Date() < deadline { usleep(10_000) }
        #expect(provider.tunnels.count == 3)

        #expect(try broker.ptySessionLifecycle(
            configuration: configuration,
            sessionID: "session",
            lifecycleID: "generation"
        ) == .intentionallyClosed)
        #expect(throws: RemotePTYLifecycleError.self) {
            try broker.startPTYBridge(
                configuration: configuration,
                sessionID: "session",
                lifecycleID: "generation",
                attachmentID: "surface",
                command: nil,
                requireExisting: true
            )
        }
    }

    @Test("forced local proxy port is used verbatim")
    func forcedLocalProxyPort() throws {
        let provider = FakeTunnelProvider()
        let broker = RemoteProxyBroker(tunnelProvider: provider, clock: ManualRetryClock())
        let configuration = makeConfiguration(localProxyPort: 45_678)
        let lease = broker.acquire(configuration: configuration, remotePath: "/r/p") { _ in }
        defer { lease.release() }

        #expect(try #require(provider.tunnels.first).localPort == 45_678)
    }

    private func makeConfiguration(localProxyPort: Int? = nil) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "test@example.invalid",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: localProxyPort,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )
    }
}
