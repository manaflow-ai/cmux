import CmuxCore
import CmuxFoundation
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@MainActor
@Suite("Native SSH conflicted-master reset")
struct NativeSSHControlMasterResetTests {
    private let sharingOptions = SSHConnectionSharingOptions(userID: 501)
    private let resolvedOptions = [
        "ControlMaster=auto",
        "ControlPersist=600",
        "ControlPath=/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567",
    ]

    @Test("A successful global exit notifies every shared-master owner")
    func successfulExitNotifiesSiblingOwners() async throws {
        let recorder = ResetEventRecorder()
        let broker = makeBroker(processRunner: RecordingProcessRunner())
        let first = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "first-alias",
            options: resolvedOptions
        ))
        let second = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "second-alias",
            options: resolvedOptions
        ))
        let firstObservation = try #require(
            broker.observeControlMasterResets(for: first) {
                recorder.record()
            }
        )
        let secondObservation = try #require(
            broker.observeControlMasterResets(for: second) {
                recorder.record()
            }
        )

        #expect(await broker.resetConflictedControlMaster(for: first) == .reset)
        #expect(recorder.count == 2)
        _ = firstObservation
        _ = secondObservation
    }

    @Test("Authentication-lock deferrals retry before resetting")
    func authenticationDeferralRetries() async {
        let clock = ManualBrokerClock()
        let runner = RetryThenSuccessResetRunner(retryCount: 2)
        let broker = makeBroker(clock: clock, processRunner: runner)
        let lease = broker.retainWorkspace(configuration(
            owner: UUID(),
            options: resolvedOptions
        ))

        let reset = Task { @MainActor in
            await broker.resetConflictedControlMaster(for: lease)
        }
        #expect(await clock.nextRequestedDelay() == 2_000)
        await clock.resumeNextSleep()
        #expect(await clock.nextRequestedDelay() == 2_000)
        await clock.resumeNextSleep()

        #expect(
            await reset.value == NativeSSHControlMasterResetOutcome.reset
        )
        #expect(runner.requestCount == 3)
    }

    @Test("An unresolved reset does not invalidate a different host")
    func unresolvedResetDoesNotNotifyDifferentHost() async throws {
        let firstRecorder = ResetEventRecorder()
        let secondRecorder = ResetEventRecorder()
        let broker = makeBroker(processRunner: RecordingProcessRunner())
        let unresolvedOptions = [
            "ControlMaster=auto",
            "ControlPath=/tmp/cmux-ssh-501-%C",
        ]
        let first = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "first.example.test",
            options: unresolvedOptions
        ))
        let second = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "second.example.test",
            options: unresolvedOptions
        ))
        let firstObservation = try #require(
            broker.observeControlMasterResets(for: first) {
                firstRecorder.record()
            }
        )
        let secondObservation = try #require(
            broker.observeControlMasterResets(for: second) {
                secondRecorder.record()
            }
        )

        #expect(await broker.resetConflictedControlMaster(for: first) == .reset)
        #expect(firstRecorder.count == 1)
        #expect(secondRecorder.count == 0)
        _ = firstObservation
        _ = secondObservation
    }

    @Test("Unresolved templates never coalesce distinct effective identities")
    func unresolvedTemplatesUseConservativeKeys() throws {
        let first = configuration(
            owner: UUID(),
            destination: "shared-alias",
            options: [
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-%C",
                "User=alice",
            ]
        )
        let second = configuration(
            owner: UUID(),
            destination: "shared-alias",
            options: [
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-%C",
                "User=bob",
            ]
        )
        let matchingSibling = configuration(
            owner: UUID(),
            destination: "shared-alias",
            options: [
                "ControlMaster=auto",
                "ControlPath=/tmp/cmux-ssh-501-%C",
                "User=alice",
            ]
        )
        let firstKey = try #require(NativeSSHControlMasterResetKey(
            configuration: first,
            sharingOptions: sharingOptions
        ))
        let secondKey = try #require(NativeSSHControlMasterResetKey(
            configuration: second,
            sharingOptions: sharingOptions
        ))
        let matchingSiblingKey = try #require(NativeSSHControlMasterResetKey(
            configuration: matchingSibling,
            sharingOptions: sharingOptions
        ))

        #expect(firstKey != secondKey)
        #expect(firstKey.impactScope != secondKey.impactScope)
        #expect(firstKey != matchingSiblingKey)
        #expect(firstKey.impactScope == matchingSiblingKey.impactScope)
    }

    private func makeBroker(
        clock: any RemoteProxyRetryClock = RecordingImmediateClock(),
        processRunner: any RemoteSessionProcessRunning
    ) -> NativeSSHConnectionBroker {
        NativeSSHConnectionBroker(
            sharingOptions: sharingOptions,
            clock: clock,
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in },
            conflictedMasterResetRunner: processRunner
        )
    }

    private func configuration(
        owner: UUID,
        destination: String = "alice@example.test",
        options: [String]
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination,
            port: nil,
            identityFile: nil,
            sshOptions: options,
            localProxyPort: nil,
            relayPort: 64_001,
            relayID: "relay-id",
            relayToken: "token",
            localSocketPath: "/tmp/cmux-test.sock",
            ownerWorkspaceID: owner,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test"
        )
    }
}

private final class ResetEventRecorder: @unchecked Sendable {
    // lint:allow lock - event callbacks increment one test counter.
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock {
            value += 1
        }
    }
}

private final class RetryThenSuccessResetRunner:
    RemoteSessionProcessRunning,
    @unchecked Sendable
{
    // lint:allow lock - process calls consume one scripted test counter.
    private let lock = NSLock()
    private let retryCount: Int
    private var count = 0

    init(retryCount: Int) {
        self.retryCount = retryCount
    }

    var requestCount: Int {
        lock.withLock { count }
    }

    func run(
        _ request: RemoteProcessRequest,
        operation: (any RemoteTransferCancelling)?
    ) throws -> RemoteCommandResult {
        let attempt = lock.withLock {
            count += 1
            return count
        }
        if attempt <= retryCount {
            return RemoteCommandResult(
                status: NativeSSHControlMasterCleanupRequest.retryExitStatus,
                stdout: "",
                stderr: "foreground authentication still active"
            )
        }
        return RemoteCommandResult(status: 0, stdout: "", stderr: "")
    }
}
