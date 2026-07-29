import Darwin
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient timeout isolation")
struct RemoteDaemonRPCClientTimeoutIsolationTests {
    @Test("a timed-out PTY attach preserves the transport and existing PTY subscriptions")
    func timedOutPTYAttachPreservesHealthyTransportState() throws {
        let executable = try makeTransport()
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: executable).deletingLastPathComponent()
            )
        }

        let existingPTYEvent = DispatchSemaphore(value: 0)
        let unexpectedTermination = DispatchSemaphore(value: 0)
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing functionality"
            )
        ) { _ in
            unexpectedTermination.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = executable

        try client.start()
        _ = try client.attachPTY(
            sessionID: "existing-session",
            attachmentID: "existing-attachment",
            cols: 80,
            rows: 24,
            command: nil,
            requireExisting: true,
            queue: .global()
        ) { event in
            if case .data(let data) = event, data == Data("still-alive".utf8) {
                existingPTYEvent.signal()
            }
        }

        do {
            _ = try client.call(
                method: "pty.attach",
                params: [
                    "session_id": "stalled-session",
                    "attachment_id": "stalled-attachment",
                ],
                timeout: 0.05
            )
            Issue.record("stalled pty.attach unexpectedly succeeded")
        } catch {
            let nsError = error as NSError
            #expect(nsError.domain == "cmux.remote.daemon.rpc")
            #expect(nsError.code == 11)
        }

        let result = try client.call(method: "hello", params: [:], timeout: 1)
        #expect(result["transport"] as? String == "alive")
        #expect(existingPTYEvent.wait(timeout: .now() + 1) == .success)
        #expect(unexpectedTermination.wait(timeout: .now()) == .timedOut)
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

    private func makeTransport() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-daemon-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("fake-ssh-timeout")
        let script = """
        #!/bin/sh
        read_id() {
          printf '%s\\n' "$1" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p'
        }
        if IFS= read -r line; then
          id=$(read_id "$line")
          printf '{"id":%s,"ok":true,"result":{"capabilities":["proxy.stream.push"]}}\\n' "$id"
        else
          exit 1
        fi
        if IFS= read -r line; then
          id=$(read_id "$line")
          existing_token=$(printf '%s\\n' "$line" | sed -n 's/.*"client_attachment_token":"\\([^"]*\\)".*/\\1/p')
          printf '{"id":%s,"ok":true,"result":{"attachment_id":"existing-attachment","attachment_token":"%s"}}\\n' "$id" "$existing_token"
        else
          exit 1
        fi
        if ! IFS= read -r _stalled_attach; then
          exit 1
        fi
        if IFS= read -r line; then
          id=$(read_id "$line")
          printf '{"event":"pty.data","session_id":"existing-session","attachment_id":"existing-attachment","attachment_token":"%s","data_base64":"c3RpbGwtYWxpdmU="}\\n' "$existing_token"
          printf '{"id":%s,"ok":true,"result":{"transport":"alive"}}\\n' "$id"
        fi
        while IFS= read -r _line; do :; done
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        chmod(scriptURL.path, 0o755)
        return scriptURL.path
    }
}
