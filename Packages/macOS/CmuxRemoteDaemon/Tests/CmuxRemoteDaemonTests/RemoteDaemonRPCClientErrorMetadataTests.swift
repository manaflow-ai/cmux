import Darwin
import Foundation
import Testing
import CmuxCore
import CmuxFoundation
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

    @Test("PTY error events preserve their machine code")
    func ptyErrorEventPreservesCode() throws {
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "missing persistent PTY",
                missingRequiredFunctionality: "missing functionality"
            )
        ) { _ in }
        let queue = DispatchQueue(label: "cmux.remote-daemon-test.pty-event")
        let semaphore = DispatchSemaphore(value: 0)
        let received = LockedPTYEvent()
        let key = "session-1\u{1f}attachment-1\u{1f}token-1"
        client.stateQueue.sync {
            client.ptySubscriptions[key] = RemoteDaemonRPCClient.PTYSubscription(
                queue: queue,
                handler: { event in
                    received.set(event)
                    semaphore.signal()
                }
            )
        }

        let consumed = client.consumePTYEventPayload([
            "event": "pty.error",
            "session_id": "session-1",
            "attachment_id": "attachment-1",
            "attachment_token": "token-1",
            "message": "PTY input queue is full",
            "code": RemotePTYErrorCode.inputQueueFull.rawValue,
        ])

        #expect(consumed)
        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        guard case .codedError(let message, let code) = received.value else {
            Issue.record("PTY event did not preserve its coded error: \(String(describing: received.value))")
            return
        }
        #expect(message == "PTY input queue is full")
        #expect(code == RemotePTYErrorCode.inputQueueFull.rawValue)
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

private final class LockedPTYEvent: @unchecked Sendable {
    // Test-only synchronization carve-out: this callback API has no async
    // seam, so a short lock serializes the callback write and test read.
    // Safety: the stored enum is Sendable and is never exposed while mutated.
    private let lock = NSLock()
    private var stored: RemoteDaemonPTYEvent?

    var value: RemoteDaemonPTYEvent? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ event: RemoteDaemonPTYEvent) {
        lock.lock()
        stored = event
        lock.unlock()
    }
}
