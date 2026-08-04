import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient cloud CLI bridge")
struct RemoteDaemonRPCClientCloudCLITests {
    @Test("over-capacity CLI requests are rejected before local handler work")
    func overCapacityCLIRequestDoesNotInvokeHandler() {
        let handlerCalls = LockedCounter()
        let client = RemoteDaemonRPCClient(
            configuration: WorkspaceRemoteConfiguration(
                destination: "user@example-host",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil
            ),
            remotePath: "/usr/local/bin/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing required functionality"
            ),
            cliRequestHandler: { _ in
                handlerCalls.increment()
                return Data()
            },
            onUnexpectedTermination: { _ in }
        )
        client.cliRequestsInFlight = RemoteDaemonRPCClient.maxCloudCLIRequestsInFlight

        let consumed = client.consumeCLIRequestPayload([
            "event": "cli.request",
            "request_id": "req-over-capacity",
            "data_base64": Data(#"{"id":"1","method":"notification.create"}"#.utf8).base64EncodedString(),
        ])

        #expect(consumed)
        #expect(handlerCalls.value == 0)
        #expect(client.cliRequestsInFlight == RemoteDaemonRPCClient.maxCloudCLIRequestsInFlight)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
