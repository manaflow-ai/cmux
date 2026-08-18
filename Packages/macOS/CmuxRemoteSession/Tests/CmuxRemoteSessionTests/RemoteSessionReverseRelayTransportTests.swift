import Foundation
import Testing
import CmuxCore
import CmuxFoundation
@testable import CmuxRemoteSession

@Suite("Reverse relay SSH transport selection")
struct RemoteSessionReverseRelayTransportTests {
    @Test("An authenticated shared ControlMaster carries the relay")
    func sharedControlMasterIsPreferred() async throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingReverseRelayLauncher()
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            runner: runner,
            reverseRelayLauncher: launcher
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }

        let forwardRequest = try #require(runner.requests.first(where: {
            Self.isControlCommand("forward", in: $0.arguments)
        }))
        #expect(forwardRequest.arguments.contains("-R"))
        #expect(forwardRequest.arguments.contains("BatchMode=yes"))
        #expect(
            forwardRequest.arguments.contains {
                $0.hasPrefix("ControlPath=/tmp/cmux-ssh-") &&
                    $0.hasSuffix("-%C")
            }
        )
        #expect(launcher.launchCount == 0)
        #expect(coordinator.queue.sync {
            coordinator.reverseRelayControlMasterForwardSpec != nil &&
                coordinator.reverseRelayProcess == nil
        })
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
        let cancelRequest = try #require(runner.requests.first(where: {
            Self.isControlCommand("cancel", in: $0.arguments)
        }))
        #expect(
            cancelRequest.arguments.contains {
                $0.hasPrefix("ControlPath=/tmp/cmux-ssh-") &&
                    $0.hasSuffix("-%C")
            }
        )
        #expect(
            Self.reverseForward(in: cancelRequest.arguments)
                == Self.reverseForward(in: forwardRequest.arguments)
        )
    }

    @Test("Connection preparation retains an already-resolved path")
    func connectionPreparationRetainsResolvedPath() async throws {
        let runner = RecordingProcessRunner()
        let registry = PermissiveNativeSSHControlMasterOwnershipRegistry()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                providesResolvedControlPath: false,
                ownershipRegistry: registry
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }
        coordinator.queue.sync {
            coordinator.resolvedControlMasterSSHOptions = [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=\(ResolvedControlPathFixture.path)",
            ]
        }
        #expect(registry.retainedControlPaths.isEmpty)

        try coordinator.queue.sync {
            try coordinator.prepareControlMasterOwnershipLocked()
        }
        let options = coordinator.queue.sync {
            coordinator.resolvedControlMasterSSHOptions
        }

        #expect(options?.contains(
            "ControlPath=\(ResolvedControlPathFixture.path)"
        ) == true)
        #expect(
            registry.retainedControlPaths ==
                [ResolvedControlPathFixture.path]
        )
        #expect(runner.requests.isEmpty)
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("An unresolved cmux template reaches the shared master without a config probe")
    func unresolvedTemplateUsesOpenSSHExpansionWithoutConfigProbe() async throws {
        let runner = RecordingProcessRunner { request in
            if request.arguments.first == "-G" {
                return RemoteCommandResult(
                    status: 0,
                    stdout: "",
                    stderr: ""
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                providesResolvedControlPath: false
            )
        let coordinator = fixture.coordinator
        defer {
            try? FileManager.default.removeItem(at: fixture.scratchDirectory)
        }

        let outcome = coordinator.queue.sync {
            coordinator.startReverseRelayViaControlMasterLocked(
                forwardSpec: "127.0.0.1:64044:127.0.0.1:55001",
                relayPort: 64_044
            )
        }

        guard case .started = outcome else {
            Issue.record("Expected the unresolved template to use OpenSSH's native %C expansion")
            return
        }
        #expect(!runner.requests.contains(where: { $0.arguments.first == "-G" }))
        #expect(runner.requests.contains(where: {
            Self.isControlCommand("forward", in: $0.arguments)
        }))
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("An explicitly disabled ControlMaster uses the standalone fallback")
    func disabledControlMasterUsesStandaloneFallback() async throws {
        let runner = RecordingProcessRunner()
        let launcher = RecordingReverseRelayLauncher()
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            runner: runner,
            reverseRelayLauncher: launcher,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=no",
                "ControlPath=~/.ssh/custom-%C",
            ]
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        var launches = launcher.launches.makeAsyncIterator()
        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }

        let launch = try #require(await launches.next())
        #expect(launch.arguments.starts(with: ["-N", "-T", "-S", "none"]))
        #expect(!runner.requests.contains(where: {
            Self.isControlCommand("forward", in: $0.arguments)
        }))
        #expect(coordinator.queue.sync {
            coordinator.reverseRelayControlMasterForwardSpec == nil &&
                coordinator.reverseRelayProcess === launcher.process
        })
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("An unresolved cmux ControlPath uses the shared master directly")
    func unresolvedOwnedControlPathUsesSharedMaster() async throws {
        let runner = RecordingProcessRunner()
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            runner: runner,
            providesResolvedControlPath: false
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }

        #expect(!runner.requests.contains(where: { $0.arguments.first == "-G" }))
        #expect(runner.requests.contains(where: {
            Self.isControlCommand("forward", in: $0.arguments)
        }))
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("Repeated shared-master relays do not repeat ControlPath resolution")
    func repeatedSharedMasterRelaysDoNotRepeatControlPathResolution() async throws {
        let baseRunner = RecordingProcessRunner()
        let runner = FlakyResolvedControlPathProcessRunner(
            base: baseRunner,
            failureCount: 1
        )
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            runner: runner,
            providesResolvedControlPath: false
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }
        let forwardSpec = "127.0.0.1:64044:127.0.0.1:55001"

        let first = coordinator.queue.sync {
            coordinator.startReverseRelayViaControlMasterLocked(
                forwardSpec: forwardSpec,
                relayPort: 64_044
            )
        }
        guard case .started = first else {
            Issue.record("Expected the unresolved template to use the shared master")
            return
        }
        coordinator.queue.sync {
            coordinator.stopReverseRelayViaControlMasterLocked()
        }
        let second = coordinator.queue.sync {
            coordinator.startReverseRelayViaControlMasterLocked(
                forwardSpec: forwardSpec,
                relayPort: 64_044
            )
        }

        guard case .started = second else {
            Issue.record("Expected the cached unresolved template to remain reusable")
            return
        }
        #expect(runner.resolutionAttempts == 0)
        #expect(baseRunner.requests.contains(where: {
            Self.isControlCommand("forward", in: $0.arguments)
        }))
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A cached custom ControlPath remains reusable")
    func cachedCustomControlPathRemainsReusable() async throws {
        let runner = RecordingProcessRunner()
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

        let first = coordinator.queue.sync {
            coordinator.startReverseRelayViaControlMasterLocked(
                forwardSpec: "127.0.0.1:64044:127.0.0.1:55001",
                relayPort: 64_044
            )
        }
        coordinator.queue.sync {
            coordinator.stopReverseRelayViaControlMasterLocked()
        }
        let second = coordinator.queue.sync {
            coordinator.startReverseRelayViaControlMasterLocked(
                forwardSpec: "127.0.0.1:64044:127.0.0.1:55002",
                relayPort: 64_044
            )
        }

        guard case .started = first else {
            Issue.record("Expected the initial custom-master relay to start")
            return
        }
        guard case .started = second else {
            Issue.record("Expected the cached custom master to remain usable")
            return
        }
        #expect(runner.requests.filter {
            Self.isControlCommand("forward", in: $0.arguments)
        }.count == 2)
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A standalone non-bind failure publishes only a generic retry status")
    func standaloneFailurePublishesSanitizedStatus() async throws {
        let rawFailure = "Permission denied: secret diagnostic"
        let host = ReverseRelayRecoveryHost()
        let clock = ManualBrokerClock()
        let runner = RecordingProcessRunner { request in
            if Self.isControlCommand("forward", in: request.arguments) {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "Control socket connect: No such file or directory"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let launcher = RecordingReverseRelayLauncher()
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            host: host,
            runner: runner,
            reverseRelayLauncher: launcher,
            clock: clock
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        var launches = launcher.launches.makeAsyncIterator()
        var statuses = host.daemonStatuses.makeAsyncIterator()
        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }
        _ = try #require(await launches.next())
        launcher.emitTermination(detail: rawFailure)

        let status = try #require(await statuses.next())
        #expect(status.detail == "test relay unavailable")
        #expect(status.detail?.contains(rawFailure) == false)
        #expect(await clock.nextRequestedDelay() == 2_000)
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A standalone bind failure never exits a shared master")
    func standaloneConflictFailsClosed() async throws {
        let relayPort = 64_047
        let clock = ManualBrokerClock()
        let runner = RecordingProcessRunner { request in
            if Self.isControlCommand("forward", in: request.arguments) {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "Control socket connect: No such file or directory"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let launcher = RecordingReverseRelayLauncher()
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            runner: runner,
            reverseRelayLauncher: launcher,
            relayPort: relayPort,
            clock: clock
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        var launches = launcher.launches.makeAsyncIterator()
        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }
        let launch = try #require(await launches.next())
        #expect(launch.arguments.starts(with: ["-N", "-T", "-S", "none"]))
        #expect(!launch.arguments.contains(where: {
            $0.localizedCaseInsensitiveContains("ControlPath")
        }))
        #expect(coordinator.queue.sync {
            coordinator.reverseRelayProcess === launcher.process
        })
        #expect(!runner.requests.contains(where: Self.isMetadataInstallRequest))

        launcher.emitTermination(
            detail: "Error: remote port forwarding failed for listen port \(relayPort)"
        )
        launcher.emitStartupReady()

        #expect(await clock.nextRequestedDelay() == 2_000)
        coordinator.queue.sync {}
        #expect(!runner.requests.contains(where: Self.isMetadataInstallRequest))
        #expect(!runner.requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))
        #expect(coordinator.queue.sync {
            coordinator.reverseRelayProcess == nil
        })
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

    private static func reverseForward(in arguments: [String]) -> String? {
        guard let reverseIndex = arguments.firstIndex(of: "-R") else {
            return nil
        }
        let valueIndex = arguments.index(after: reverseIndex)
        return arguments.indices.contains(valueIndex)
            ? arguments[valueIndex]
            : nil
    }

    private static func isMetadataInstallRequest(
        _ request: RemoteProcessRequest
    ) -> Bool {
        request.arguments.last?.contains("CMUXRELAYAUTH") == true
    }
}
