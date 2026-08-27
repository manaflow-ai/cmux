import Darwin
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient error metadata")
struct RemoteDaemonRPCClientErrorMetadataTests {
    @Test("daemon RPC errors preserve their structured code")
    func structuredCodeIsPreserved() throws {
        let executable = try makeErrorTransport()
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: executable).deletingLastPathComponent()
            )
        }
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing functionality"
            )
        ) { _ in }
        defer { client.stop() }
        client.transportExecutableOverride = executable

        try client.start()

        do {
            _ = try client.call(method: "pty.attach", params: [:], timeout: 1)
            Issue.record("pty.attach unexpectedly succeeded")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon.rpc")
            #expect(nsError.code == 14)
            #expect(
                nsError.localizedDescription ==
                    "pty.attach failed (unavailable): too many PTY sessions are already starting"
            )
            #expect(
                nsError.userInfo["cmux.remote.daemon.rpc.error_code"] as? String ==
                    "unavailable"
            )
        }
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
            preserveAfterTerminalExit: false,
            persistentDaemonSlot: nil
        )
    }

    private func makeErrorTransport() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-daemon-rpc-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("fake-ssh-error")
        let script = """
        #!/bin/sh
        if IFS= read -r line; then
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"ok":true,"result":{"capabilities":["proxy.stream.push"]}}\\n' "$id"
        else
          exit 1
        fi
        if IFS= read -r line; then
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"ok":false,"error":{"code":"unavailable","message":"too many PTY sessions are already starting"}}\\n' "$id"
        fi
        while IFS= read -r _line; do :; done
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        chmod(scriptURL.path, 0o755)
        return scriptURL.path
    }
}
