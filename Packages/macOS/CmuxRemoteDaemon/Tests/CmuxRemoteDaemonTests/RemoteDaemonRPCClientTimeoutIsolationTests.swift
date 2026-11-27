import Darwin
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient timeout isolation")
struct RemoteDaemonRPCClientTimeoutIsolationTests {
    @Test("a timed-out PTY attach cancels remotely while preserving the transport and subscriptions")
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
                missingRequiredFunctionality: "missing functionality",
                cloudNotificationClearWorkspaceInvalid: "invalid workspace",
                cloudNotificationClearWorkspaceDenied: "workspace denied",
                cloudNotificationClearSurfaceInvalid: "invalid surface"
            )
        ) { _ in
            unexpectedTermination.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = executable

        try client.start()
        #expect(client.daemonVersion == "0.64.22")
        let existingAttachment = try client.attachPTY(
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
        #expect(existingAttachment.replayByteCount == 11)

        do {
            _ = try client.call(
                method: "pty.attach",
                params: [
                    "session_id": "stalled-session",
                    "attachment_id": "stalled-attachment",
                    "client_attachment_token": "stalled-token",
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
        #expect(existingPTYEvent.wait(timeout: .now() + 5) == .success)
        #expect(unexpectedTermination.wait(timeout: .now()) == .timedOut)
    }

    @Test("a timed-out PTY attach does not wait for a blocked cancellation write")
    func timedOutPTYAttachBoundsCancellationWrite() throws {
        let executable = try makeIdleTransport()
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: executable).deletingLastPathComponent()
            )
        }

        let unexpectedTermination = DispatchSemaphore(value: 0)
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing functionality",
                cloudNotificationClearWorkspaceInvalid: "invalid workspace",
                cloudNotificationClearWorkspaceDenied: "workspace denied",
                cloudNotificationClearSurfaceInvalid: "invalid surface"
            )
        ) { _ in
            unexpectedTermination.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = executable
        try client.start()

        // Occupy the transport writer before the attach deadline handler
        // runs. The writer must already be held when the cancellation is
        // queued; holding it in response to a daemon event instead races the
        // attach RPC deadline, because nothing bounds that event's round trip
        // on a loaded host. The write stays held until the test ends, so the
        // cancellation deadline, not a write completion, decides the outcome.
        let writeBlockEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        client.writeQueue.async {
            writeBlockEntered.signal()
            releaseWrite.wait()
        }
        defer { releaseWrite.signal() }
        try #require(writeBlockEntered.wait(timeout: .now() + 5) == .success)

        // This is the handler a timed-out `pty.attach` invokes before it
        // throws the timeout error; the first test covers that wiring.
        let cancellationReturned = DispatchSemaphore(value: 0)
        DispatchQueue(label: "com.cmux.tests.remote-daemon.timed-out-attach").async {
            client.sendPTYAttachCancellation(
                requestID: 2,
                attachParams: [
                    "session_id": "stalled-session",
                    "attachment_id": "stalled-attachment",
                    "client_attachment_token": "stalled-token",
                ]
            )
            cancellationReturned.signal()
        }

        #expect(cancellationReturned.wait(timeout: .now() + 5) == .success)
        #expect(unexpectedTermination.wait(timeout: .now() + 10) == .success)
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
          printf '{"id":%s,"ok":true,"result":{"version":"0.64.22","capabilities":["proxy.stream.push"]}}\\n' "$id"
        else
          exit 1
        fi
        if IFS= read -r line; then
          id=$(read_id "$line")
          existing_token=$(printf '%s\\n' "$line" | sed -n 's/.*"client_attachment_token":"\\([^"]*\\)".*/\\1/p')
          printf '{"id":%s,"ok":true,"result":{"attachment_id":"existing-attachment","attachment_token":"%s","replay_bytes":11}}\\n' "$id" "$existing_token"
        else
          exit 1
        fi
        if ! IFS= read -r stalled_attach; then
          exit 1
        fi
        stalled_id=$(read_id "$stalled_attach")
        printf '{"event":"pty.data","session_id":"existing-session","attachment_id":"existing-attachment","attachment_token":"%s","data_base64":"YXR0YWNoLXJlYWQ="}\\n' "$existing_token"
        if IFS= read -r line; then
          cancel_request_id=$(printf '%s\\n' "$line" | sed -n 's/.*"request_id":\\([0-9][0-9]*\\).*/\\1/p')
          cancel_session=$(printf '%s\\n' "$line" | sed -n 's/.*"session_id":"\\([^"]*\\)".*/\\1/p')
          cancel_attachment=$(printf '%s\\n' "$line" | sed -n 's/.*"attachment_id":"\\([^"]*\\)".*/\\1/p')
          cancel_token=$(printf '%s\\n' "$line" | sed -n 's/.*"client_attachment_token":"\\([^"]*\\)".*/\\1/p')
          case "$line" in *'"method":"pty.attach.cancel"'*) ;; *) exit 2 ;; esac
          if [ "$cancel_request_id" != "$stalled_id" ] ||
             [ "$cancel_session" != "stalled-session" ] ||
             [ "$cancel_attachment" != "stalled-attachment" ] ||
             [ "$cancel_token" != "stalled-token" ]; then
            exit 3
          fi
        else
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

    /// A daemon that answers `hello` and then only drains its input.
    private func makeIdleTransport() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-daemon-idle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("fake-ssh-idle")
        let script = """
        #!/bin/sh
        if IFS= read -r line; then
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          printf '{"id":%s,"ok":true,"result":{"version":"0.64.22","capabilities":["proxy.stream.push"]}}\\n' "$id"
        else
          exit 1
        fi
        while IFS= read -r _line; do :; done
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        chmod(scriptURL.path, 0o755)
        return scriptURL.path
    }
}
