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
            forwardRequest.arguments.contains(
                "ControlPath=\(SSHConnectionSharingOptions().defaultControlPath)"
            )
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
            cancelRequest.arguments.contains(
                "ControlPath=\(SSHConnectionSharingOptions().defaultControlPath)"
            )
        )
        #expect(
            Self.reverseForward(in: cancelRequest.arguments)
                == Self.reverseForward(in: forwardRequest.arguments)
        )
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

    @Test("A bind conflict exits a cmux-owned master")
    func ownedConflictExitsMaster() async throws {
        let clock = ManualBrokerClock()
        let runner = RecordingProcessRunner { request in
            if Self.isControlCommand("forward", in: request.arguments) {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: """
                    mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 64044
                    muxclient: master forward request failed
                    """
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let launcher = RecordingReverseRelayLauncher()
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            runner: runner,
            reverseRelayLauncher: launcher,
            clock: clock
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }

        #expect(await clock.nextRequestedDelay() == 2_000)
        #expect(runner.requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))
        let exitRequest = try #require(runner.requests.first(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))
        #expect(
            exitRequest.arguments.contains(
                "ControlPath=\(SSHConnectionSharingOptions().defaultControlPath)"
            )
        )
        #expect(launcher.launchCount == 0)
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A custom ControlPath is never exited")
    func customControlPathFailsClosed() async throws {
        let clock = ManualBrokerClock()
        let runner = RecordingProcessRunner { request in
            if Self.isControlCommand("forward", in: request.arguments) {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "remote port forwarding failed for listen port 64044"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let launcher = RecordingReverseRelayLauncher()
        let fixture = try await RemoteSessionReverseRelayStartupTests.makeCoordinator(
            runner: runner,
            reverseRelayLauncher: launcher,
            sshOptions: [
                "StrictHostKeyChecking=accept-new",
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=~/.ssh/custom-%C",
                "ControlPath=\(SSHConnectionSharingOptions().defaultControlPath)",
            ],
            clock: clock
        )
        let coordinator = fixture.coordinator
        defer { try? FileManager.default.removeItem(at: fixture.scratchDirectory) }

        coordinator.queue.sync {
            coordinator.daemonReady = true
            coordinator.daemonRemotePath = "/tmp/cmuxd-remote"
            coordinator.startReverseRelayLocked(remotePath: "/tmp/cmuxd-remote")
        }

        #expect(await clock.nextRequestedDelay() == 2_000)
        #expect(!runner.requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))
        let forwardRequest = try #require(runner.requests.first(where: {
            Self.isControlCommand("forward", in: $0.arguments)
        }))
        #expect(forwardRequest.arguments.contains("ControlPath=~/.ssh/custom-%C"))
        #expect(coordinator.queue.sync {
            !coordinator.reverseRelayStartupPhase.isRecovering &&
                coordinator.reverseRelayStartupPhase.allowsRelayLaunch
        })
        #expect(launcher.launchCount == 0)
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
        #expect(status.detail == String(
            localized: "remoteSession.reverseRelay.unavailableRetrying",
            defaultValue: "Remote SSH relay unavailable; retrying in 2 seconds"
        ))
        #expect(status.detail?.contains(rawFailure) == false)
        #expect(await clock.nextRequestedDelay() == 2_000)
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("A late standalone bind failure triggers owned-master recovery")
    func lateStandaloneConflictTriggersRecovery() async throws {
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

        launcher.emitTermination(
            detail: "Error: remote port forwarding failed for listen port \(relayPort)"
        )

        #expect(await clock.nextRequestedDelay() == 2_000)
        #expect(runner.requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))
        #expect(coordinator.queue.sync {
            coordinator.reverseRelayProcess == nil
        })
        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("Standalone termination waits for the complete stderr tail")
    func standaloneTerminationDrainsStderr() async throws {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            i=0
            while [ "$i" -lt 1000 ]; do
              printf 'diagnostic-noise-%s\n' "$i" >&2
              i=$((i + 1))
            done
            printf 'Error: remote port forwarding failed for listen port 64044\n' >&2
            exit 255
            """,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        let relayProcess = FoundationRemoteReverseRelayProcess(
            process: process,
            stderrPipe: stderrPipe
        )
        let (details, continuation) = AsyncStream<String?>.makeStream()

        try process.run()
        relayProcess.captureTermination { detail in
            continuation.yield(detail)
            continuation.finish()
        }

        var iterator = details.makeAsyncIterator()
        #expect(
            await iterator.next()
                == "Error: remote port forwarding failed for listen port 64044"
        )
        #expect(process.terminationStatus == 255)
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
}
