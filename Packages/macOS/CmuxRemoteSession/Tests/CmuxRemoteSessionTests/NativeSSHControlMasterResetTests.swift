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
    private let firstResolvedPath =
        "/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567"
    private let secondResolvedPath =
        "/tmp/cmux-ssh-501-89abcdef0123456789abcdef0123456789abcdef"
    private let resolvedOptions = [
        "ControlMaster=auto",
        "ControlPersist=600",
        "ControlPath=/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567",
    ]
    private let unresolvedOptions = [
        "ControlMaster=auto",
        "ControlPersist=600",
        "ControlPath=/tmp/cmux-ssh-501-%C",
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
        _ = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "second-alias",
            options: resolvedOptions
        ))
        let firstObservation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
                recorder.record()
            }
        )
        let secondObservation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
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

    @Test("Transient reset runner errors retry before resetting")
    func transientRunnerErrorsRetry() async {
        let clock = ManualBrokerClock()
        let runner = ThrowThenSuccessResetRunner(throwCount: 2)
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

        #expect(await reset.value == .reset)
        #expect(runner.requestCount == 3)
    }

    @Test("Expanded paths keep unrelated hosts isolated")
    func expandedPathsDoNotNotifyDifferentHost() async throws {
        let firstRecorder = ResetEventRecorder()
        let secondRecorder = ResetEventRecorder()
        let runner = ResolvingResetRunner(pathsByDestination: [
            "first.example.test": firstResolvedPath,
            "second.example.test": secondResolvedPath,
        ])
        let broker = makeBroker(processRunner: runner)
        let first = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "first.example.test",
            options: unresolvedOptions
        ))
        _ = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "second.example.test",
            options: unresolvedOptions
        ))
        let firstObservation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
                firstRecorder.record()
            }
        )
        let secondObservation = try #require(
            broker.observeControlMasterResets(controlPath: secondResolvedPath) {
                secondRecorder.record()
            }
        )

        #expect(await broker.resetConflictedControlMaster(for: first) == .reset)
        #expect(firstRecorder.count == 1)
        #expect(secondRecorder.count == 0)
        #expect(runner.exitRequests.count == 1)
        #expect(runner.exitRequests[0].arguments.contains(
            "ControlPath=\(firstResolvedPath)"
        ))
        #expect(!runner.exitRequests[0].arguments.contains(
            "ControlPath=/tmp/cmux-ssh-501-%C"
        ))
        let unresolvedLock = try #require(
            sharingOptions.foregroundAuthenticationLockPath(
                destination: "first.example.test",
                port: nil,
                options: unresolvedOptions
            )
        )
        let resolvedLock = try #require(
            sharingOptions.foregroundAuthenticationLockPath(
                destination: "first.example.test",
                port: nil,
                options: resolvedOptions
            )
        )
        #expect(unresolvedLock != resolvedLock)
        #expect(runner.exitRequests[0].arguments.contains(unresolvedLock))
        #expect(!runner.exitRequests[0].arguments.contains(resolvedLock))
        _ = firstObservation
        _ = secondObservation
    }

    @Test("Different aliases resolving to one socket share reset fanout")
    func aliasesResolvingToSamePathShareFanout() async throws {
        let recorder = ResetEventRecorder()
        let runner = ResolvingResetRunner(pathsByDestination: [
            "first-alias": firstResolvedPath,
            "second-alias": firstResolvedPath,
        ])
        let broker = makeBroker(processRunner: runner)
        let first = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "first-alias",
            options: unresolvedOptions
        ))
        _ = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "second-alias",
            options: unresolvedOptions
        ))
        let firstObservation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
                recorder.record()
            }
        )
        let secondObservation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
                recorder.record()
            }
        )

        #expect(await broker.resetConflictedControlMaster(for: first) == .reset)
        #expect(recorder.count == 2)
        #expect(runner.exitRequests.count == 1)
        _ = firstObservation
        _ = secondObservation
    }

    @Test("Concurrent aliases coalesce only after exact path resolution")
    func concurrentAliasesCoalesceByResolvedPath() async {
        let runner = BlockingResolvingResetRunner(
            resolvedPath: firstResolvedPath
        )
        let broker = makeBroker(processRunner: runner)
        let first = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "first-alias",
            options: unresolvedOptions
        ))
        let second = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "second-alias",
            options: unresolvedOptions
        ))

        let firstReset = Task { @MainActor in
            await broker.resetConflictedControlMaster(for: first)
        }
        let secondReset = Task { @MainActor in
            await broker.resetConflictedControlMaster(for: second)
        }
        var resolutions = runner.resolutions.makeAsyncIterator()
        #expect(await resolutions.next() != nil)
        #expect(await resolutions.next() != nil)
        var exits = runner.exits.makeAsyncIterator()
        #expect(await exits.next() != nil)
        runner.finishExit()

        #expect(await firstReset.value == .reset)
        #expect(await secondReset.value == .reset)
        #expect(runner.exitCount == 1)
    }

    @Test("A coalesced alias keeps its resolved-socket reset alive")
    func coalescedAliasKeepsResetAlive() async throws {
        let runner = BlockingResolvingResetRunner(
            resolvedPath: firstResolvedPath
        )
        let recorder = ResetEventRecorder()
        let broker = makeBroker(processRunner: runner)
        let first = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "first-alias",
            options: unresolvedOptions
        ))
        let second = broker.retainWorkspace(configuration(
            owner: UUID(),
            destination: "second-alias",
            options: unresolvedOptions
        ))
        let observation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
                recorder.record()
            }
        )

        let firstReset = Task { @MainActor in
            await broker.resetConflictedControlMaster(for: first)
        }
        var resolutions = runner.resolutions.makeAsyncIterator()
        #expect(await resolutions.next() != nil)
        var exits = runner.exits.makeAsyncIterator()
        #expect(await exits.next() != nil)
        let secondReset = Task { @MainActor in
            await broker.resetConflictedControlMaster(for: second)
        }
        #expect(await resolutions.next() != nil)
        await Task.yield()
        broker.releaseWorkspace(first)
        runner.finishExit()

        #expect(await firstReset.value == .reset)
        #expect(await secondReset.value == .reset)
        #expect(recorder.count == 1)
        _ = observation
    }

    @Test("A successful exit still invalidates after its lease is released")
    func successfulExitAfterReleaseStillInvalidates() async throws {
        let runner = BlockingControlMasterResetRunner()
        let recorder = ResetEventRecorder()
        let broker = makeBroker(processRunner: runner)
        let lease = broker.retainWorkspace(configuration(
            owner: UUID(),
            options: resolvedOptions
        ))
        let observation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
                recorder.record()
            }
        )

        let reset = Task { @MainActor in
            await broker.resetConflictedControlMaster(for: lease)
        }
        var starts = runner.starts.makeAsyncIterator()
        #expect(await starts.next() != nil)
        broker.releaseWorkspace(lease)
        runner.finish()

        #expect(await reset.value == .reset)
        #expect(recorder.count == 1)
        _ = observation
    }

    @Test("ControlPath resolution failure never exits a master")
    func resolutionFailureFailsClosed() async {
        let runner = RecordingProcessRunner { request in
            if request.arguments.contains("-G") {
                return RemoteCommandResult(
                    status: 255,
                    stdout: "",
                    stderr: "configuration resolution failed"
                )
            }
            return RemoteCommandResult(status: 0, stdout: "", stderr: "")
        }
        let broker = makeBroker(processRunner: runner)
        let lease = broker.retainWorkspace(configuration(
            owner: UUID(),
            options: unresolvedOptions
        ))

        let outcome = await broker.resetConflictedControlMaster(for: lease)

        guard case .ignored = outcome else {
            Issue.record("Expected resolution failure to be ignored")
            return
        }
        #expect(!runner.requests.contains(where: {
            $0.arguments.contains("-O") && $0.arguments.contains("exit")
        }))
    }

    @Test("A reset-wrapper no-op remains deferred and emits no reset")
    func resetWrapperNoOpDoesNotCountAsReset() async throws {
        let clock = ManualBrokerClock()
        let runner = FixedStatusResetRunner(
            status: NativeSSHControlMasterCleanupRequest.resetSkippedExitStatus
        )
        let recorder = ResetEventRecorder()
        let broker = makeBroker(clock: clock, processRunner: runner)
        let lease = broker.retainWorkspace(configuration(
            owner: UUID(),
            options: resolvedOptions
        ))
        let observation = try #require(
            broker.observeControlMasterResets(controlPath: firstResolvedPath) {
                recorder.record()
            }
        )

        let reset = Task { @MainActor in
            await broker.resetConflictedControlMaster(for: lease)
        }
        #expect(await clock.nextRequestedDelay() == 2_000)
        await clock.resumeNextSleep()
        #expect(await clock.nextRequestedDelay() == 2_000)
        await clock.resumeNextSleep()

        guard case .deferred = await reset.value else {
            Issue.record("Expected skipped reset attempts to remain deferred")
            return
        }
        #expect(runner.requestCount == 3)
        #expect(recorder.count == 0)
        _ = observation
    }

    @Test("Cleanup wrapper distinguishes ordinary and reset-only no-ops")
    func cleanupWrapperUsesResetOnlySkippedStatus() throws {
        let request = NativeSSHControlMasterCleanupRequest(
            arguments: ["-V"],
            environment: nil,
            authenticationLockPath: "/dev/null/cmux-test.lock"
        )
        let normalInvocation = request.processInvocation
        let resetInvocation = request.processInvocation(
            noOpExitStatus:
                NativeSSHControlMasterCleanupRequest.resetSkippedExitStatus
        )
        let runner = RemoteSessionProcessRunner()

        let normal = try runner.run(
            RemoteProcessRequest(
                executable: normalInvocation.executableURL.path,
                arguments: normalInvocation.arguments,
                timeout: 2
            ),
            operation: nil
        )
        let reset = try runner.run(
            RemoteProcessRequest(
                executable: resetInvocation.executableURL.path,
                arguments: resetInvocation.arguments,
                timeout: 2
            ),
            operation: nil
        )

        #expect(normal.status == 0)
        #expect(
            reset.status ==
                NativeSSHControlMasterCleanupRequest.resetSkippedExitStatus
        )
    }

    @Test("Unresolved authorization keys remain owner-scoped")
    func unresolvedTemplatesUseConservativeAuthorizationKeys() throws {
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
        #expect(firstKey != matchingSiblingKey)
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
