import CmuxCore
import CmuxFoundation
import Foundation
import Testing
@testable import CmuxRemoteSession

@Suite("Inherited reverse-forward recovery")
struct RemoteSessionInheritedForwardRecoveryTests {
    @Test("Metadata probe requires exact relay identity and slot")
    func metadataProbeMatchesExactLeaseIdentity() throws {
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
        #expect(try Self.runShellScript(script, home: home) == 64)
    }

    @Test("Matching metadata cancels only the stale forward and retries it")
    func matchingMetadataRecoversStaleForward() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(mode: .success)
        let launcher = RecordingReverseRelayLauncher()
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(
                runner: runner,
                reverseRelayLauncher: launcher
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

        let requests = runner.requests
        let forwards = requests.filter {
            Self.isControlCommand("forward", in: $0.arguments)
        }
        let cancellations = requests.filter {
            Self.isControlCommand("cancel", in: $0.arguments)
        }
        let probe = try #require(
            requests.first(where: Self.isMetadataOwnershipProbe)
        )
        #expect(forwards.count == 2)
        #expect(cancellations.count == 1)
        #expect(
            Self.reverseForward(in: cancellations[0].arguments)
                == "127.0.0.1:64044"
        )
        #expect(
            probe.arguments.contains(
                "ControlPath=\(ResolvedControlPathFixture.path)"
            )
        )
        #expect(probe.arguments.contains("BatchMode=yes"))
        #expect(!requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
        }))
        #expect(launcher.launchCount == 0)
        #expect(coordinator.queue.sync {
            coordinator.reverseRelayControlMasterForwardSpec != nil &&
                coordinator.reverseRelayProcess == nil
        })

        _ = await coordinator.stopAndWait(cleanupScope: .transport)
    }

    @Test("Mismatched metadata leaves an ambiguous listener untouched")
    func metadataMismatchFailsClosed() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(
            mode: .metadataMismatch
        )
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(runner: runner)
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
            Issue.record("Expected the collision to remain unresolved")
            return
        }
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

    @Test("A rejected cancel does not retry or exit the master")
    func rejectedCancellationFailsClosed() async throws {
        let runner = InheritedForwardRecoveryProcessRunner(
            mode: .cancellationFailure
        )
        let fixture = try await RemoteSessionReverseRelayStartupTests
            .makeCoordinator(runner: runner)
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
            Issue.record("Expected the rejected cancel to fail closed")
            return
        }
        let requests = runner.requests
        #expect(
            requests.filter {
                Self.isControlCommand("forward", in: $0.arguments)
            }.count == 1
        )
        #expect(
            requests.filter {
                Self.isControlCommand("cancel", in: $0.arguments)
            }.count == 1
        )
        #expect(!requests.contains(where: {
            Self.isControlCommand("exit", in: $0.arguments)
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

    private static func reverseForward(
        in arguments: [String]
    ) -> String? {
        guard let reverseIndex = arguments.firstIndex(of: "-R") else {
            return nil
        }
        let valueIndex = arguments.index(after: reverseIndex)
        return arguments.indices.contains(valueIndex)
            ? arguments[valueIndex]
            : nil
    }

    private static func isMetadataOwnershipProbe(
        _ request: RemoteProcessRequest
    ) -> Bool {
        request.arguments.last?.contains("tr -d") == true &&
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

private final class InheritedForwardRecoveryProcessRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    enum Mode: Equatable, Sendable {
        case success
        case metadataMismatch
        case cancellationFailure
    }

    // lint:allow lock - synchronous test requests consume one scripted counter.
    private let lock = NSLock()
    private let mode: Mode
    private var _requests: [RemoteProcessRequest] = []
    private var forwardAttempts = 0

    init(mode: Mode) {
        self.mode = mode
    }

    var requests: [RemoteProcessRequest] {
        lock.withLock { _requests }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        lock.withLock {
            _requests.append(request)
            if Self.isControlCommand("forward", in: request.arguments) {
                forwardAttempts += 1
                if forwardAttempts == 1 {
                    return RemoteCommandResult(
                        status: 255,
                        stdout: "",
                        stderr:
                            "remote port forwarding failed for listen port 64044"
                    )
                }
            }
            if Self.isMetadataOwnershipProbe(request),
               mode == .metadataMismatch {
                return RemoteCommandResult(
                    status: 64,
                    stdout: "",
                    stderr: ""
                )
            }
            if Self.isControlCommand("cancel", in: request.arguments),
               mode == .cancellationFailure {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "cancel failed"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
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
            request.arguments.last?.contains(
                "relay-startup-cancellation"
            ) == true
    }
}
