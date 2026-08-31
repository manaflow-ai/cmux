import CmuxCore
import CmuxFoundation
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Inherited reverse-forward recovery")
struct RemoteSessionInheritedForwardRecoveryTests {
    @Test("Persistent metadata probe accepts rotated auth for the exact slot")
    func persistentMetadataProbeUsesDurableSlotIdentity() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-relay-probe-\(UUID().uuidString)",
                isDirectory: true
            )
        let relayDirectory = home
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("relay", isDirectory: true)
        try FileManager.default.createDirectory(
            at: relayDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let authFile = relayDirectory.appendingPathComponent("64044.auth")
        let slotFile = relayDirectory.appendingPathComponent("64044.slot")
        let token = String(repeating: "a", count: 64)
        try """
        {"relay_id":"relay-startup-cancellation","relay_token":"\(token)"}
        """.write(to: authFile, atomically: true, encoding: .utf8)
        try "ssh-test\n".write(
            to: slotFile,
            atomically: true,
            encoding: .utf8
        )
        let script =
            RemoteSessionCoordinator.remoteRelayMetadataOwnershipProbeScript(
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: token,
                persistentDaemonSlot: "ssh-test"
            )

        #expect(try Self.runShellScript(script, home: home) == 0)

        try "other-slot".write(
            to: slotFile,
            atomically: true,
            encoding: .utf8
        )
        #expect(try Self.runShellScript(script, home: home) == 64)

        try """
        {"relay_id":"another-relay","relay_token":"\(token)"}
        """.write(to: authFile, atomically: true, encoding: .utf8)
        try "ssh-test".write(
            to: slotFile,
            atomically: true,
            encoding: .utf8
        )
        #expect(try Self.runShellScript(script, home: home) == 0)

        try FileManager.default.removeItem(at: authFile)
        #expect(try Self.runShellScript(script, home: home) == 64)
    }

    @Test("Nonpersistent metadata probe requires exact relay credentials")
    func nonpersistentMetadataProbeUsesTransientCredentials() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-relay-probe-\(UUID().uuidString)",
                isDirectory: true
            )
        let relayDirectory = home
            .appendingPathComponent(".cmux", isDirectory: true)
            .appendingPathComponent("relay", isDirectory: true)
        try FileManager.default.createDirectory(
            at: relayDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        let authFile = relayDirectory.appendingPathComponent("64044.auth")
        let slotFile = relayDirectory.appendingPathComponent("64044.slot")
        let token = String(repeating: "a", count: 64)
        try """
        {"relay_id":"relay-startup-cancellation","relay_token":"\(token)"}
        """.write(to: authFile, atomically: true, encoding: .utf8)
        let script =
            RemoteSessionCoordinator.remoteRelayMetadataOwnershipProbeScript(
                relayPort: 64_044,
                relayID: "relay-startup-cancellation",
                relayToken: token,
                persistentDaemonSlot: nil
            )

        #expect(try Self.runShellScript(script, home: home) == 0)

        try """
        {"relay_id":"another-relay","relay_token":"\(token)"}
        """.write(to: authFile, atomically: true, encoding: .utf8)
        #expect(try Self.runShellScript(script, home: home) == 64)

        try FileManager.default.removeItem(at: authFile)
        try "unexpected-slot".write(
            to: slotFile,
            atomically: true,
            encoding: .utf8
        )
        #expect(try Self.runShellScript(script, home: home) == 64)
    }

    @Test("Matching transient metadata authorizes an inherited-master reap")
    func matchingMetadataAuthorizesMasterReap() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(mode: .success)
        let launcher = RecordingReverseRelayLauncher()
        let clock = ManualBrokerClock()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                reverseRelayLauncher: launcher,
                clock: clock
            )
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }

        #expect(await clock.nextRequestedDelay() == 2_000)
        let requests = runner.requests
        let forwards = requests.filter {
            Self.isControlCommand("forward", in: $0.arguments)
        }
        let probe = try #require(
            requests.first(where: Self.isMetadataOwnershipProbe)
        )
        #expect(forwards.count == 1)
        #expect(
            probe.arguments.contains(
                "ControlPath=\(ResolvedControlPathFixture.path)"
            )
        )
        #expect(probe.arguments.contains("BatchMode=yes"))
        #expect(requests.filter {
            Self.isControlCommand("exit", in: $0.arguments)
        }.count == 1)
        #expect(!requests.contains(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))
        #expect(launcher.launchCount == 0)
        #expect(coordinator.queue.sync {
            !coordinator.daemonReady &&
                coordinator.reverseRelayControlMasterForwardSpec == nil &&
                coordinator.reverseRelayProcess == nil
        })

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("Mismatched metadata leaves an ambiguous listener untouched")
    func metadataMismatchFailsClosed() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(
            mode: .metadataMismatch
        )
        let clock = ManualBrokerClock()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(runner: runner, clock: clock)
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }

        #expect(await clock.nextRequestedDelay() == 2_000)
        let requests = runner.requests
        #expect(
            requests.filter {
                Self.isControlCommand("forward", in: $0.arguments)
            }.count == 1
        )
        #expect(requests.contains(where: Self.isMetadataOwnershipProbe))
        #expect(!requests.contains(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))
        #expect(!requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A rejected master exit does not cancel or retry the forward")
    func rejectedMasterExitFailsClosed() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(
            mode: .exitFailure
        )
        let clock = ManualBrokerClock()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(runner: runner, clock: clock)
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }

        #expect(await clock.nextRequestedDelay() == 2_000)
        let requests = runner.requests
        #expect(
            requests.filter {
                Self.isControlCommand("forward", in: $0.arguments)
            }.count == 1
        )
        #expect(
            requests.filter {
                Self.isControlCommand("exit", in: $0.arguments)
            }.count == 1
        )
        #expect(!requests.contains(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A transient metadata failure can recover on the next relay attempt")
    func transientMetadataFailureRetriesRecovery() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(
            mode: .transientMetadataFailure
        )
        let host = ReverseRelayRecoveryHost()
        let clock = ManualBrokerClock()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                host: host,
                runner: runner,
                clock: clock
            )
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }
        let readyStatus = WorkspaceRemoteDaemonStatus(
            state: .ready,
            detail: "Remote daemon ready",
            version: "0.64.20",
            name: "cmuxd-remote",
            capabilities: ["reverse-relay"],
            remotePath: "/tmp/cmuxd-remote"
        )

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.publishDaemonStatus(
                readyStatus.state,
                detail: readyStatus.detail,
                version: readyStatus.version,
                name: readyStatus.name,
                capabilities: readyStatus.capabilities,
                remotePath: readyStatus.remotePath
            )
            coordinator.startReverseRelayLocked(
                remotePath: "/tmp/cmuxd-remote"
            )
        }
        var statuses = host.daemonStatuses.makeAsyncIterator()
        #expect(await statuses.next() == readyStatus)
        #expect(await clock.nextRequestedDelay() == 2_000)
        await clock.resumeNextSleep()
        let firstRecoveryStatus = try #require(await statuses.next())
        #expect(firstRecoveryStatus.state != .error)
        #expect(await clock.nextRequestedDelay() == 2_000)
        let secondRecoveryStatus = try #require(await statuses.next())
        #expect(secondRecoveryStatus.state != .error)

        let requests = runner.requests
        #expect(
            requests.filter {
                Self.isControlCommand("forward", in: $0.arguments)
            }.count == 2
        )
        #expect(
            requests.filter(Self.isMetadataOwnershipProbe).count == 2
        )
        #expect(
            requests.filter {
                Self.isControlCommand("exit", in: $0.arguments)
            }.count == 1
        )
        #expect(!requests.contains(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A custom ControlPath never authorizes stale-forward recovery")
    func customControlPathFailsClosed() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(mode: .success)
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                    "ControlMaster=auto",
                    "ControlPersist=600",
                    "ControlPath=~/.ssh/custom-%C",
                ]
            )
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(
                at: fixture.scratchDirectory
            )
        }

        let outcome = coordinator.queue.sync {
            coordinator.startReverseRelayViaControlMasterLocked(
                forwardSpec: "127.0.0.1:64044:127.0.0.1:55001",
                relayPort: 64_044
            )
        }

        guard case .bindingConflict = outcome else {
            Issue.record("Expected the custom master collision to fail closed")
            return
        }
        let requests = runner.requests
        #expect(
            requests.filter {
                Self.isControlCommand("forward", in: $0.arguments)
            }.count == 1
        )
        #expect(!requests.contains(where: Self.isMetadataOwnershipProbe))
        #expect(!requests.contains(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))
        #expect(!requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    private static func isControlCommand(
        _ command: String,
        in arguments: [String]
    ) -> Bool {
        arguments.indices.dropLast().contains(where: {
            arguments[$0] == "-O" && arguments[$0 + 1] == command
        })
    }

    private static func isMetadataOwnershipProbe(
        _ request: RemoteProcessRequest
    ) -> Bool {
        request.arguments.last?.contains("tr -d") == true &&
            request.arguments.last?.contains("auth_file=") == true &&
            request.arguments.last?.contains(
                "relay-startup-cancellation"
            ) == true
    }

    private static func runShellScript(
        _ script: String,
        home: URL
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
