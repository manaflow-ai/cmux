import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemon WebSocket transport lifecycle and multiplexing")
struct RemoteDaemonWebSocketTransportTests {
    @Test("RemoteDaemonWebSocketMultiplexer registers and dispatches callbacks by task identifier")
    func multiplexerDispatchesByTaskIdentifier() {
        let multiplexer = RemoteDaemonWebSocketMultiplexer()
        let delegate1 = RemoteDaemonWebSocketDelegate()
        let delegate2 = RemoteDaemonWebSocketDelegate()

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "wss://127.0.0.1:65534/test")!)
        let task1 = session.webSocketTask(with: request)
        let task2 = session.webSocketTask(with: request)

        multiplexer.register(delegate: delegate1, for: task1)
        multiplexer.register(delegate: delegate2, for: task2)

        #expect(!delegate1.isClosed)
        #expect(!delegate2.isClosed)

        multiplexer.urlSession(session, webSocketTask: task1, didOpenWithProtocol: nil)
        #expect(delegate1.waitForOpen(timeout: 0.5))

        multiplexer.urlSession(session, webSocketTask: task2, didCloseWith: .goingAway, reason: nil)
        #expect(delegate2.isClosed)

        multiplexer.unregister(task: task1)
        multiplexer.unregister(task: task2)
    }

    @Test("RemoteDaemonRPCClient uses a shared URLSession across instances")
    func sharedWebSocketSessionReusedAcrossClients() {
        let session1 = RemoteDaemonRPCClient.sharedWebSocketSession
        let session2 = RemoteDaemonRPCClient.sharedWebSocketSession
        #expect(session1 === session2)
        #expect(session1.configuration.httpCookieStorage == nil)
        #expect(session1.configuration.urlCache == nil)
    }

    @Test("RemoteDaemonRPCClient deinit stops transport without crash")
    func clientDeinitStopsTransport() {
        let config = WorkspaceRemoteConfiguration(
            destination: "user@example",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
        )
        let strings = RemoteDaemonStrings(
            missingPersistentPTYCapability: "missing persistent PTY",
            missingRequiredFunctionality: "missing functionality",
            cloudNotificationClearWorkspaceInvalid: "invalid workspace",
            cloudNotificationClearWorkspaceDenied: "workspace denied",
            cloudNotificationClearSurfaceInvalid: "invalid surface"
        )
        var client: RemoteDaemonRPCClient? = RemoteDaemonRPCClient(
            configuration: config,
            remotePath: "/bin/echo",
            strings: strings
        ) { _ in }
        #expect(client != nil)
        client = nil
        #expect(client == nil)
    }
}
