import Darwin
import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteDaemon

@Suite("RemoteDaemonRPCClient transport keepalive")
struct RemoteDaemonRPCClientKeepaliveTests {
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

    private func strings() -> RemoteDaemonStrings {
        RemoteDaemonStrings(
            missingPersistentPTYCapability: "missing persistent PTY",
            missingRequiredFunctionality: "missing functionality",
            cloudNotificationClearWorkspaceInvalid: "invalid workspace",
            cloudNotificationClearWorkspaceDenied: "workspace denied",
            cloudNotificationClearSurfaceInvalid: "invalid surface"
        )
    }

    private func makeTransportScript(name: String, body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-daemon-keepalive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent(name)
        try Data(body.utf8).write(to: scriptURL, options: .atomic)
        chmod(scriptURL.path, 0o755)
        return scriptURL.path
    }

    private func helloResponseScript(loopBody: String) -> String {
        """
        #!/bin/sh
        respond() {
          line="$1"
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
          if [ -z "$id" ]; then id=1; fi
          printf '{"id":%s,"ok":true,"result":{"capabilities":["proxy.stream.push"],"name":"fake","version":"t","remote_path":"/fake"}}\\n' "$id"
        }
        if IFS= read -r line; then
          respond "$line"
        else
          exit 1
        fi
        \(loopBody)
        """
    }

    @Test("stdio transport keepalive reports a wedged daemon with live pipes")
    func wedgedTransportTerminates() throws {
        let executable = try makeTransportScript(
            name: "fake-ssh-wedged",
            body: helloResponseScript(loopBody: "while IFS= read -r _line; do :; done\n")
        )
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable).deletingLastPathComponent()) }
        let terminated = DispatchSemaphore(value: 0)
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: strings(),
            keepaliveInterval: 0.2,
            keepaliveTimeout: 1.0
        ) { _ in
            terminated.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = executable

        try client.start()

        #expect(terminated.wait(timeout: .now() + 5.0) == .success)
    }

    @Test("stdio transport keepalive accepts healthy hello responses")
    func healthyTransportDoesNotTerminate() throws {
        let executable = try makeTransportScript(
            name: "fake-ssh-healthy",
            body: helloResponseScript(loopBody: "while IFS= read -r line; do respond \"$line\"; done\n")
        )
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable).deletingLastPathComponent()) }
        let terminated = DispatchSemaphore(value: 0)
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: strings(),
            keepaliveInterval: 0.2,
            keepaliveTimeout: 1.0
        ) { _ in
            terminated.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = executable

        try client.start()

        #expect(terminated.wait(timeout: .now() + 2.0) == .timedOut)
    }

    @Test("stdio keepalive does not kill a valid in-flight RPC")
    func validSlowRPCDoesNotTerminateTransport() throws {
        let executable = try makeTransportScript(
            name: "fake-ssh-slow-rpc",
            body: helloResponseScript(loopBody: """
            while IFS= read -r line; do
              case "$line" in
                *'"method":"proxy.open"'*)
                  sleep 1
                  id=$(printf '%s\\n' "$line" | sed -n 's/.*"id":\\([0-9][0-9]*\\).*/\\1/p')
                  printf '{"id":%s,"ok":true,"result":{"stream_id":"slow-stream"}}\\n' "$id"
                  ;;
                *) respond "$line" ;;
              esac
            done
            """)
        )
        defer { try? FileManager.default.removeItem(at: URL(fileURLWithPath: executable).deletingLastPathComponent()) }
        let terminated = DispatchSemaphore(value: 0)
        let client = RemoteDaemonRPCClient(
            configuration: configuration(),
            remotePath: "/fake/cmuxd-remote",
            strings: strings(),
            keepaliveInterval: 0.1,
            keepaliveTimeout: 0.2
        ) { _ in
            terminated.signal()
        }
        defer { client.stop() }
        client.transportExecutableOverride = executable

        try client.start()

        #expect(try client.openStream(host: "127.0.0.1", port: 22) == "slow-stream")
        #expect(terminated.wait(timeout: .now() + 0.5) == .timedOut)
    }
}
