import CmuxCore
import CmuxRemoteDaemon
import CmuxRemoteWorkspace
import Foundation
import Testing

@testable import CmuxRemoteSession

@Suite
struct RemoteRelaySlotTeardownTests {
    @Test
    func cleanupStopsPersistentSlotAndRemovesShellState() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-relay-slot-teardown-\(UUID().uuidString)")
        let relayDirectory = home.appendingPathComponent(".cmux/relay")
        let shellDirectory = relayDirectory.appendingPathComponent("64008.shell")
        let daemonURL = home.appendingPathComponent("cmuxd-remote-test")
        let shutdownArgumentsURL = home.appendingPathComponent("shutdown.args")
        defer { try? fileManager.removeItem(at: home) }

        try fileManager.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        try "shell state".write(
            to: shellDirectory.appendingPathComponent(".bashrc"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$HOME/shutdown.args\"\n".write(
            to: daemonURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemonURL.path)
        try daemonURL.path.write(
            to: relayDirectory.appendingPathComponent("64008.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        try "ssh-test-slot".write(
            to: relayDirectory.appendingPathComponent("64008.slot"),
            atomically: true,
            encoding: .utf8
        )
        try "auth".write(
            to: relayDirectory.appendingPathComponent("64008.auth"),
            atomically: true,
            encoding: .utf8
        )
        try "pts/1".write(
            to: relayDirectory.appendingPathComponent("64008.tty"),
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(relayPort: 64008),
        ]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(fileManager.fileExists(atPath: shutdownArgumentsURL.path))
        if fileManager.fileExists(atPath: shutdownArgumentsURL.path) {
            let arguments = try String(contentsOf: shutdownArgumentsURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(arguments == "serve --persistent-stop --slot ssh-test-slot")
        }
        #expect(!fileManager.fileExists(atPath: shellDirectory.path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.auth").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.daemon_path").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.slot").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64008.tty").path))
    }

    @Test
    func transportCleanupPreservesPersistentSlotAndShellState() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-relay-transport-cleanup-\(UUID().uuidString)")
        let relayDirectory = home.appendingPathComponent(".cmux/relay")
        let shellDirectory = relayDirectory.appendingPathComponent("64009.shell")
        let socketAddressURL = home.appendingPathComponent(".cmux/socket_addr")
        defer { try? fileManager.removeItem(at: home) }

        try fileManager.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        try "127.0.0.1:64009".write(to: socketAddressURL, atomically: true, encoding: .utf8)
        for suffix in ["auth", "daemon_path", "slot", "tty"] {
            try suffix.write(
                to: relayDirectory.appendingPathComponent("64009.\(suffix)"),
                atomically: true,
                encoding: .utf8
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteRelayTransportMetadataCleanupScript(relayPort: 64009),
        ]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(!fileManager.fileExists(atPath: socketAddressURL.path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64009.auth").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64009.tty").path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64009.daemon_path").path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64009.slot").path))
        #expect(fileManager.fileExists(atPath: shellDirectory.path))
    }

    @Test
    func failedShutdownPreservesPersistentOwnershipState() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-relay-failed-shutdown-\(UUID().uuidString)")
        let relayDirectory = home.appendingPathComponent(".cmux/relay")
        let shellDirectory = relayDirectory.appendingPathComponent("64011.shell")
        let daemonURL = home.appendingPathComponent("cmuxd-remote-old")
        let socketAddressURL = home.appendingPathComponent(".cmux/socket_addr")
        defer { try? fileManager.removeItem(at: home) }

        try fileManager.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 2\n".write(to: daemonURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemonURL.path)
        try "127.0.0.1:64011".write(to: socketAddressURL, atomically: true, encoding: .utf8)
        try daemonURL.path.write(
            to: relayDirectory.appendingPathComponent("64011.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        for suffix in ["auth", "slot", "tty"] {
            try suffix.write(
                to: relayDirectory.appendingPathComponent("64011.\(suffix)"),
                atomically: true,
                encoding: .utf8
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(relayPort: 64011),
        ]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(!fileManager.fileExists(atPath: socketAddressURL.path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.auth").path))
        #expect(!fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.tty").path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.daemon_path").path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.slot").path))
        #expect(fileManager.fileExists(atPath: shellDirectory.path))
    }

    @Test
    func coordinatorStopUsesFinalPersistentSlotTeardown() throws {
        let runner = SpyProcessRunner()
        let provider = IntentionalCleanupTestTunnelProvider()
        let coordinator = RemoteSessionCoordinator(
            host: IntentionalCleanupTestHost(),
            configuration: WorkspaceRemoteConfiguration(
                destination: "user@example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: 64_010,
                relayID: "relay-id",
                relayToken: "relay-token",
                localSocketPath: "/tmp/cmux-test.sock",
                terminalStartupCommand: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-test-slot"
            ),
            proxyBroker: RemoteProxyBroker(tunnelProvider: provider),
            manifestRepository: RemoteDaemonManifestRepository(
                homeDirectory: FileManager.default.temporaryDirectory
            ),
            processRunner: runner,
            reachabilityProbe: IntentionalCleanupNoopReachabilityProbe(),
            relayCommandRewriter: IntentionalCleanupRelayCommandRewriter(),
            buildInfo: IntentionalCleanupBuildInfo(),
            daemonStrings: RemoteDaemonStrings(
                missingPersistentPTYCapability: "",
                missingRequiredFunctionality: ""
            ),
            strings: RemoteSessionStrings(
                connectedVMNoProxyFormat: "%@",
                suspendedDetailFormat: "%@"
            )
        )

        coordinator.stop()
        coordinator.queue.sync {}

        let cleanupCommand = try #require(runner.requests.last?.arguments.last)
        #expect(cleanupCommand.contains("serve --persistent-stop --slot"))
        #expect(cleanupCommand.contains("64010.shell"))
    }
}
