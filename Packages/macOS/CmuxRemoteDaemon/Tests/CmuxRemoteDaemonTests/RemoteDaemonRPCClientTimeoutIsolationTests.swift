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
                missingRequiredFunctionality: "missing functionality"
            )
        ) { _ in
            unexpectedTermination.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = executable

        try client.start()
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
        #expect(existingPTYEvent.wait(timeout: .now() + 1) == .success)
        #expect(unexpectedTermination.wait(timeout: .now()) == .timedOut)
    }

    @Test("a timed-out PTY attach does not wait for a blocked cancellation write")
    func timedOutPTYAttachBoundsCancellationWrite() throws {
        let executable = try makeTransport()
        defer {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: executable).deletingLastPathComponent()
            )
        }

        let stalledAttachRead = DispatchSemaphore(value: 0)
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
            if case .data(let data) = event, data == Data("attach-read".utf8) {
                stalledAttachRead.signal()
            }
        }

        let writeBlockEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeBlockQueue = DispatchQueue(label: "com.cmux.tests.remote-daemon.block-cancellation-write")
        writeBlockQueue.async {
            guard stalledAttachRead.wait(timeout: .now() + 2) == .success else {
                releaseWrite.signal()
                return
            }
            client.writeQueue.async {
                writeBlockEntered.signal()
                releaseWrite.wait()
            }
        }
        // One-shot failure safety keeps a regressed synchronous cancellation
        // from stranding the test process; ordinary cleanup is deterministic.
        let cleanupFired = DispatchSemaphore(value: 0)
        let cleanupTimer = DispatchSource.makeTimerSource(queue: writeBlockQueue)
        cleanupTimer.schedule(deadline: .now() + 5)
        cleanupTimer.setEventHandler {
            cleanupFired.signal()
            releaseWrite.signal()
        }
        cleanupTimer.resume()
        defer {
            cleanupTimer.cancel()
            releaseWrite.signal()
        }

        let callFinished = DispatchSemaphore(value: 0)
        let callTimedOut = DispatchSemaphore(value: 0)
        let unexpectedCallResult = DispatchSemaphore(value: 0)
        let callQueue = DispatchQueue(label: "com.cmux.tests.remote-daemon.call-with-blocked-cancellation")
        callQueue.async {
            defer { callFinished.signal() }
            do {
                _ = try client.call(
                    method: "pty.attach",
                    params: [
                        "session_id": "stalled-session",
                        "attachment_id": "stalled-attachment",
                        "client_attachment_token": "stalled-token",
                    ],
                    timeout: 1
                )
                unexpectedCallResult.signal()
            } catch {
                let nsError = error as NSError
                if nsError.domain == "cmux.remote.daemon.rpc", nsError.code == 11 {
                    callTimedOut.signal()
                } else {
                    unexpectedCallResult.signal()
                }
            }
        }

        #expect(writeBlockEntered.wait(timeout: .now() + 2) == .success)
        #expect(callFinished.wait(timeout: .now() + 6) == .success)
        #expect(callTimedOut.wait(timeout: .now()) == .success)
        #expect(unexpectedCallResult.wait(timeout: .now()) == .timedOut)
        #expect(cleanupFired.wait(timeout: .now()) == .timedOut)
        #expect(unexpectedTermination.wait(timeout: .now() + 2) == .success)
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
}
