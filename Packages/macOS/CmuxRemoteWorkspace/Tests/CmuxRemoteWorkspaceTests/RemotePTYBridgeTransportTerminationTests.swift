import CmuxCore
@testable import CmuxRemoteDaemon
import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("Remote PTY bridge transport termination", .serialized)
struct RemotePTYBridgeTransportTerminationTests {
    @Test("transport teardown synchronously closes a bridge already handling failure")
    func transportTeardownClosesFailingBridge() throws {
        let scriptURL = try makeFailingTransportScript()
        defer { try? FileManager.default.removeItem(at: scriptURL.deletingLastPathComponent()) }

        let serverReference = RemotePTYBridgeServerReference()
        let teardownReturned = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let rpc = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing functionality"
            )
        ) { _ in
            if let server = serverReference.load() {
                _ = server.stopAndWaitForDisposition()
            }
            teardownReturned.signal()
        }
        rpc.transportExecutableOverride = scriptURL.path
        defer { rpc.stop() }
        try rpc.start()

        let server = RemotePTYBridgeServer(
            rpcClient: rpc,
            sessionID: "session",
            lifecycleID: "lifecycle",
            attachmentID: "surface",
            command: nil,
            requireExisting: true,
            strings: TestPTYBridgeStrings(),
            onStop: { _ in stopped.signal() }
        )
        serverReference.store(server)
        defer { server.stop() }
        let endpoint = try server.start()
        let client = BridgeTestClient(endpoint: endpoint)
        defer { client.cancel() }
        client.send(Data("{\"token\":\"\(endpoint.token)\",\"cols\":80,\"rows\":24}\n".utf8))
        #expect(client.waitForReceived { data, _ in
            String(decoding: data, as: UTF8.self).contains("\"attachment_token\":\"server-token\"")
        })

        #expect(teardownReturned.wait(timeout: .now() + 2) == .success)
        #expect(stopped.wait(timeout: .now()) == .success)
    }

    private func configuration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "fake-host",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: nil
        )
    }

    private func makeFailingTransportScript() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-pty-transport-race-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appending(path: "fake-ssh")
        let script = """
        #!/bin/sh
        if ! IFS= read -r hello; then exit 1; fi
        hello_id=$(printf '%s\n' "$hello" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        printf '{"id":%s,"ok":true,"result":{"capabilities":["proxy.stream.push","pty.session","pty.session.token","pty.write.notification","pty.resize.notification"],"name":"fake","version":"test","remote_path":"/fake"}}\n' "$hello_id"
        if ! IFS= read -r attach; then exit 1; fi
        attach_id=$(printf '%s\n' "$attach" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
        printf '{"id":%s,"ok":true,"result":{"attachment_id":"surface","attachment_token":"server-token"}}\n' "$attach_id"
        sleep 0.1
        exit 255
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        chmod(scriptURL.path, 0o755)
        return scriptURL
    }
}
