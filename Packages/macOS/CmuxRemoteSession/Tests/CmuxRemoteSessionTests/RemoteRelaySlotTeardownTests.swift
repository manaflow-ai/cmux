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
            RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(
                relayPort: 64008,
                persistentDaemonSlot: "ssh-test-slot"
            ),
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
            RemoteSessionCoordinator.remoteRelayTransportMetadataCleanupScript(
                relayPort: 64009,
                persistentDaemonSlot: "slot"
            ),
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
            RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(
                relayPort: 64011,
                persistentDaemonSlot: "slot"
            ),
        ]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(fileManager.fileExists(atPath: socketAddressURL.path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.auth").path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.tty").path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.daemon_path").path))
        #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64011.slot").path))
        #expect(fileManager.fileExists(atPath: shellDirectory.path))
    }

    @Test
    func mismatchedSlotCannotStopOrDeleteAnotherRelayOwner() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-relay-mismatched-owner-\(UUID().uuidString)")
        let relayDirectory = home.appendingPathComponent(".cmux/relay")
        let shellDirectory = relayDirectory.appendingPathComponent("64012.shell")
        let daemonURL = home.appendingPathComponent("cmuxd-remote-owner")
        let shutdownArgumentsURL = home.appendingPathComponent("shutdown.args")
        let socketAddressURL = home.appendingPathComponent(".cmux/socket_addr")
        defer { try? fileManager.removeItem(at: home) }

        try fileManager.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" > \"$HOME/shutdown.args\"\n".write(
            to: daemonURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: daemonURL.path)
        try "127.0.0.1:64012".write(to: socketAddressURL, atomically: true, encoding: .utf8)
        try daemonURL.path.write(
            to: relayDirectory.appendingPathComponent("64012.daemon_path"),
            atomically: true,
            encoding: .utf8
        )
        for (suffix, value) in [
            ("auth", "auth"),
            ("slot", "another-workspace-slot"),
            ("tty", "pts/1"),
        ] {
            try value.write(
                to: relayDirectory.appendingPathComponent("64012.\(suffix)"),
                atomically: true,
                encoding: .utf8
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(
                relayPort: 64012,
                persistentDaemonSlot: "expected-workspace-slot"
            ),
        ]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(!fileManager.fileExists(atPath: shutdownArgumentsURL.path))
        #expect(fileManager.fileExists(atPath: socketAddressURL.path))
        for suffix in ["auth", "daemon_path", "slot", "tty"] {
            #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64012.\(suffix)").path))
        }
        #expect(fileManager.fileExists(atPath: shellDirectory.path))
    }

    @Test(arguments: MalformedSlotCleanupScope.allCases)
    func malformedConfiguredSlotFailsClosed(_ cleanupScope: MalformedSlotCleanupScope) throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-relay-malformed-slot-\(cleanupScope.rawValue)-\(UUID().uuidString)")
        let relayDirectory = home.appendingPathComponent(".cmux/relay")
        let shellDirectory = relayDirectory.appendingPathComponent("64013.shell")
        let socketAddressURL = home.appendingPathComponent(".cmux/socket_addr")
        defer { try? fileManager.removeItem(at: home) }

        try fileManager.createDirectory(at: shellDirectory, withIntermediateDirectories: true)
        try "127.0.0.1:64013".write(to: socketAddressURL, atomically: true, encoding: .utf8)
        for suffix in ["auth", "daemon_path", "tty"] {
            try suffix.write(
                to: relayDirectory.appendingPathComponent("64013.\(suffix)"),
                atomically: true,
                encoding: .utf8
            )
        }

        let script = switch cleanupScope {
        case .persistentSlot:
            RemoteSessionCoordinator.remoteRelayMetadataCleanupScript(
                relayPort: 64013,
                persistentDaemonSlot: "../malformed-slot"
            )
        case .transport:
            RemoteSessionCoordinator.remoteRelayTransportMetadataCleanupScript(
                relayPort: 64013,
                persistentDaemonSlot: "../malformed-slot"
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(fileManager.fileExists(atPath: socketAddressURL.path))
        for suffix in ["auth", "daemon_path", "tty"] {
            #expect(fileManager.fileExists(atPath: relayDirectory.appendingPathComponent("64013.\(suffix)").path))
        }
        #expect(fileManager.fileExists(atPath: shellDirectory.path))
    }

    @Test
    func coordinatorStopUsesFinalPersistentSlotTeardown() async throws {
        let runner = SpyProcessRunner()
        let coordinator = makeCoordinator(runner: runner)

        let succeeded = await coordinator.stopAndWait(cleanupScope: .persistentSlot)

        let cleanupCommand = try #require(runner.requests.last?.arguments.last)
        #expect(succeeded)
        #expect(cleanupCommand.contains("serve --persistent-stop --slot"))
        #expect(cleanupCommand.contains("64010.shell"))
    }

    @Test
    func coordinatorReportsFailedFinalCleanup() async {
        let runner = SpyProcessRunner(result: RemoteCommandResult(status: 1, stdout: "", stderr: "failed"))
        let coordinator = makeCoordinator(runner: runner)

        let succeeded = await coordinator.stopAndWait(cleanupScope: .persistentSlot)

        #expect(!succeeded)
    }

    @Test
    func coordinatorTransportStopPreservesPersistentSlot() async throws {
        let runner = SpyProcessRunner()
        let coordinator = makeCoordinator(runner: runner)

        let succeeded = await coordinator.stopAndWait(cleanupScope: .transport)

        let cleanupCommand = try #require(runner.requests.last?.arguments.last)
        #expect(succeeded)
        #expect(!cleanupCommand.contains("serve --persistent-stop --slot"))
        #expect(!cleanupCommand.contains("rm -rf"))
        #expect(cleanupCommand.contains("64010.slot"))
    }

    @Test
    func coordinatorStopsPersistentSlotAfterTransportCleanupWithoutRelayMetadata() async throws {
        let runner = SpyProcessRunner()
        let coordinator = makeCoordinator(runner: runner, relayPort: nil)
        coordinator.queue.sync { coordinator.daemonRemotePath = ".cmux/bin/cmuxd-remote" }

        let transportSucceeded = await coordinator.stopAndWait(cleanupScope: .transport)
        #expect(transportSucceeded)
        #expect(runner.requests.isEmpty)

        let succeeded = await coordinator.stopAndWait(cleanupScope: .persistentSlot)

        let cleanupCommand = try #require(runner.requests.last?.arguments.last)
        #expect(succeeded)
        #expect(cleanupCommand.contains("$HOME/.cmux/bin/cmuxd-remote"))
        #expect(cleanupCommand.contains("serve --persistent-stop --slot"))
        #expect(!cleanupCommand.contains(".cmux/relay"))
    }

    @Test
    func coordinatorFallsBackToPersistentSlotStopWhenRelayMetadataIsMissing() async throws {
        let runner = SpyProcessRunner(results: [
            RemoteCommandResult(status: 64, stdout: "", stderr: "missing relay metadata"),
            RemoteCommandResult(status: 0, stdout: "", stderr: ""),
        ])
        let coordinator = makeCoordinator(runner: runner)
        coordinator.queue.sync { coordinator.daemonRemotePath = ".cmux/bin/cmuxd-remote" }

        let succeeded = await coordinator.stopAndWait(cleanupScope: .persistentSlot)

        #expect(succeeded)
        #expect(runner.requests.count == 2)
        let metadataCleanup = try #require(runner.requests.first?.arguments.last)
        #expect(metadataCleanup.contains("64010.slot"))
        let directCleanup = try #require(runner.requests.last?.arguments.last)
        #expect(directCleanup.contains("$HOME/.cmux/bin/cmuxd-remote"))
        #expect(directCleanup.contains("serve --persistent-stop --slot"))
        #expect(!directCleanup.contains("relay_socket="))
    }

    private func makeCoordinator(
        runner: SpyProcessRunner,
        host: any RemoteSessionHosting = IntentionalCleanupTestHost(),
        relayPort: Int? = 64_010
    ) -> RemoteSessionCoordinator {
        RemoteSessionCoordinator(
            host: host,
            configuration: WorkspaceRemoteConfiguration(
                destination: "user@example.test",
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: relayPort,
                relayID: "relay-id",
                relayToken: "relay-token",
                localSocketPath: "/tmp/cmux-test.sock",
                terminalStartupCommand: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: "ssh-test-slot"
            ),
            proxyBroker: RemoteProxyBroker(tunnelProvider: IntentionalCleanupTestTunnelProvider()),
            connectionBroker: NativeSSHConnectionBroker(),
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
    }

    enum MalformedSlotCleanupScope: String, CaseIterable, Sendable {
        case persistentSlot
        case transport
    }
}
