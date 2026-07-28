import CmuxCore
import CmuxFoundation
import CmuxRemoteWorkspace
import Foundation
import Testing
@testable import CmuxRemoteSession

@MainActor
@Suite("Native SSH connection broker")
struct NativeSSHConnectionBrokerTests {
    private let sharingOptions = SSHConnectionSharingOptions(userID: 501)
    private let resolvedOwnedSSHOptions = [
        "ControlMaster=auto",
        "ControlPersist=600",
        "ControlPath=/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567",
    ]

    @Test("Only the final workspace owner closes a shared master")
    func finalOwnerCleanup() {
        let recorder = CleanupRequestRecorder()
        let broker = makeBroker(cleanupRecorder: recorder)
        let first = configuration(
            owner: UUID(),
            destination: "first-alias",
            sshOptions: resolvedOwnedSSHOptions,
            relayPort: 64_001
        )
        let second = configuration(
            owner: UUID(),
            destination: "second-alias",
            sshOptions: resolvedOwnedSSHOptions,
            relayPort: 64_002
        )

        let firstLease = broker.retainWorkspace(first)
        let secondLease = broker.retainWorkspace(second)
        broker.releaseWorkspace(firstLease)
        #expect(recorder.requests.isEmpty)

        broker.releaseWorkspace(secondLease)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].arguments.contains(resolvedOwnedSSHOptions[2]))
        let request = recorder.requests[0]
        let lockPath = request.authenticationLockPath
        #expect(lockPath?.contains("cmux-ssh-501-auth-") == true)
        #expect(request.processInvocation.executableURL.path == "/bin/zsh")
        #expect(request.processInvocation.arguments.contains(lockPath.map { $0 + ".inflight" } ?? "") == true)
        #expect(request.processInvocation.arguments[1].contains("zsystem flock -t 4 -e"))
        #expect(request.processInvocation.arguments[1].contains("/bin/kill -0"))
    }

    @Test("A custom user-managed control path is never closed")
    func customPathIsNotCleaned() {
        let recorder = CleanupRequestRecorder()
        let broker = makeBroker(cleanupRecorder: recorder)
        let custom = configuration(
            owner: UUID(),
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=~/.ssh/custom-%C",
            ]
        )

        let customLease = broker.retainWorkspace(custom)
        broker.releaseWorkspace(customLease)

        #expect(recorder.requests.isEmpty)
    }

    @Test("Unresolved cmux templates remain unowned until ssh -G resolves them")
    func unresolvedTemplatesAreNotOwned() {
        let recorder = CleanupRequestRecorder()
        let broker = makeBroker(cleanupRecorder: recorder)
        let templateOptions = sharingOptions.mergingDefaults(into: [])
        let first = configuration(
            owner: UUID(),
            destination: "first-alias",
            sshOptions: templateOptions
        )
        let second = configuration(
            owner: UUID(),
            destination: "second-alias",
            sshOptions: templateOptions
        )

        let firstLease = broker.retainWorkspace(first)
        let secondLease = broker.retainWorkspace(second)
        #expect(firstLease.sshControlMasterLeaseGeneration == nil)
        #expect(secondLease.sshControlMasterLeaseGeneration == nil)

        broker.releaseWorkspace(firstLease)
        broker.releaseWorkspace(secondLease)
        #expect(recorder.requests.isEmpty)
    }

    @Test("A stale configuration cannot release its replacement lease")
    func staleConfigurationCannotReleaseReplacement() {
        let recorder = CleanupRequestRecorder()
        let broker = makeBroker(cleanupRecorder: recorder)
        let owner = UUID()
        let original = configuration(owner: owner, relayPort: 64_001, relayToken: "old")
        let replacement = configuration(owner: owner, relayPort: 64_002, relayToken: "new")

        let originalLease = broker.retainWorkspace(original)
        let replacementLease = broker.retainWorkspace(replacement)
        broker.releaseWorkspace(originalLease)
        #expect(recorder.requests.isEmpty)

        broker.releaseWorkspace(replacementLease)
        #expect(recorder.requests.count == 1)
    }

    @Test("An identical replacement has a distinct lease generation")
    func identicalReplacementHasDistinctGeneration() {
        let recorder = CleanupRequestRecorder()
        let broker = makeBroker(cleanupRecorder: recorder)
        let configuration = configuration(owner: UUID())

        let originalLease = broker.retainWorkspace(configuration)
        let replacementLease = broker.retainWorkspace(configuration)

        #expect(originalLease == replacementLease)
        #expect(originalLease.sshControlMasterLeaseGeneration != replacementLease.sshControlMasterLeaseGeneration)
        broker.releaseWorkspace(originalLease)
        #expect(recorder.requests.isEmpty)

        broker.releaseWorkspace(replacementLease)
        #expect(recorder.requests.count == 1)
    }

    @Test("A replacement host does not close the previous master before session cleanup")
    func replacementHostOverlapsUntilReleased() {
        let recorder = CleanupRequestRecorder()
        let broker = makeBroker(cleanupRecorder: recorder)
        let owner = UUID()
        let original = configuration(
            owner: owner,
            destination: "alice@first.example.test",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567",
            ]
        )
        let replacement = configuration(
            owner: owner,
            destination: "alice@second.example.test",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-501-89abcdef0123456789abcdef0123456789abcdef",
            ]
        )

        let originalLease = broker.retainWorkspace(original)
        let replacementLease = broker.retainWorkspace(replacement)
        #expect(recorder.requests.isEmpty)

        broker.releaseWorkspace(originalLease)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].arguments.contains(original.sshOptions[2]))

        broker.releaseWorkspace(replacementLease)
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[1].arguments.contains(replacement.sshOptions[2]))
    }

    @Test("Cleanup reuses the shared path without negotiating a replacement master")
    func cleanupArgumentsAreReuseOnly() {
        let configuration = configuration(
            owner: UUID(),
            port: 2222,
            sshOptions: sharingOptions.mergingDefaults(into: [])
        )
        let arguments = RemoteControlMasterCleanup().cleanupArguments(configuration: configuration)

        #expect(arguments.prefix(4) == ["-o", "BatchMode=yes", "-o", "ControlMaster=no"])
        #expect(arguments.contains("ControlPath=/tmp/cmux-ssh-501-%C"))
        #expect(!arguments.contains("ControlMaster=auto"))
        #expect(!arguments.contains("ControlPersist=600"))
        #expect(arguments.suffix(3) == ["-O", "exit", "alice@example.test"])
    }

    @Test("Cleanup yields to a live foreground authentication marker")
    func cleanupYieldsToLiveAuthentication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        let lockPath = root.appendingPathComponent("auth.lock").path
        let markerPath = lockPath + ".inflight"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "\(getpid())\n".write(toFile: markerPath, atomically: true, encoding: .utf8)

        let request = NativeSSHControlMasterCleanupRequest(
            arguments: ["-Z"],
            environment: nil,
            authenticationLockPath: lockPath
        )
        let invocation = request.processInvocation
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 75)
        #expect(FileManager.default.fileExists(atPath: markerPath))
    }

    @Test("Cleanup requests a retry for a recent dead authentication marker")
    func cleanupRequestsRetryForRecentDeadAuthentication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        let lockPath = root.appendingPathComponent("auth.lock").path
        let markerPath = lockPath + ".inflight"
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "2147483647\n".write(toFile: markerPath, atomically: true, encoding: .utf8)

        let request = NativeSSHControlMasterCleanupRequest(
            arguments: ["-Z"],
            environment: nil,
            authenticationLockPath: lockPath
        )
        let invocation = request.processInvocation
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 75)
        #expect(FileManager.default.fileExists(atPath: markerPath))
    }

    @Test("Same-host attempts are FIFO and separated by bounded jitter")
    func sameHostAttemptsAreSerialized() async throws {
        let clock = ManualBrokerClock()
        let events = AsyncEventLog()
        let leaderGate = AsyncLatch()
        let broker = NativeSSHConnectionBroker(
            sharingOptions: sharingOptions,
            clock: clock,
            jitterMilliseconds: { 900 },
            cleanupLauncher: { _ in }
        )
        let leaderConfiguration = configuration(
            owner: UUID(),
            destination: "first-alias",
            sshOptions: resolvedOwnedSSHOptions
        )
        let followerConfiguration = configuration(
            owner: UUID(),
            destination: "second-alias",
            sshOptions: resolvedOwnedSSHOptions
        )

        let leader = Task { @MainActor in
            try await broker.withConnectionAttempt(for: leaderConfiguration) {
                await events.record("leader-start")
                await leaderGate.wait()
                await events.record("leader-end")
            }
        }
        await events.waitForCount(1)

        let follower = Task { @MainActor in
            try await broker.withConnectionAttempt(for: followerConfiguration) {
                await events.record("follower-start")
            }
        }
        await Task.yield()
        #expect(pendingConnectionAttemptCount(in: broker, for: followerConfiguration) == 1)

        await leaderGate.open()
        try await leader.value
        let delay = await clock.nextRequestedDelay()
        #expect(delay == 350)
        #expect(await events.values == ["leader-start", "leader-end"])

        await clock.resumeNextSleep()
        try await follower.value
        #expect(await events.values == ["leader-start", "leader-end", "follower-start"])
    }

    @Test("Different hosts may connect concurrently")
    func differentHostsProceedConcurrently() async throws {
        let gate = AsyncLatch()
        let events = AsyncEventLog()
        let broker = makeBroker()
        let first = configuration(
            owner: UUID(),
            destination: "alice@first.example.test",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-501-0123456789abcdef0123456789abcdef01234567",
            ]
        )
        let second = configuration(
            owner: UUID(),
            destination: "alice@second.example.test",
            sshOptions: [
                "ControlMaster=auto",
                "ControlPersist=600",
                "ControlPath=/tmp/cmux-ssh-501-89abcdef0123456789abcdef0123456789abcdef",
            ]
        )

        let firstTask = Task { @MainActor in
            try await broker.withConnectionAttempt(for: first) {
                await events.record("first")
                await gate.wait()
            }
        }
        let secondTask = Task { @MainActor in
            try await broker.withConnectionAttempt(for: second) {
                await events.record("second")
                await gate.wait()
            }
        }

        await events.waitForCount(2)
        #expect(Set(await events.values) == ["first", "second"])
        await gate.open()
        try await firstTask.value
        try await secondTask.value
    }

    @Test("Cancelling a queued attempt removes its waiter")
    func cancellationRemovesWaiter() async throws {
        let gate = AsyncLatch()
        let events = AsyncEventLog()
        let clock = RecordingImmediateClock()
        let broker = NativeSSHConnectionBroker(
            sharingOptions: sharingOptions,
            clock: clock,
            jitterMilliseconds: { 200 },
            cleanupLauncher: { _ in }
        )
        let configuration = configuration(owner: UUID())

        let leader = Task { @MainActor in
            try await broker.withConnectionAttempt(for: configuration) {
                await events.record("leader")
                await gate.wait()
            }
        }
        await events.waitForCount(1)

        let follower = Task { @MainActor in
            try await broker.withConnectionAttempt(for: configuration) {
                await events.record("cancelled-follower")
            }
        }
        await Task.yield()
        #expect(pendingConnectionAttemptCount(in: broker, for: configuration) == 1)

        follower.cancel()
        do {
            try await follower.value
            Issue.record("Expected the queued attempt to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        #expect(pendingConnectionAttemptCount(in: broker, for: configuration) == 0)

        await gate.open()
        try await leader.value
        #expect(await clock.requestedDelays.isEmpty)
        #expect(await events.values == ["leader"])
    }

    private func makeBroker(
        cleanupRecorder: CleanupRequestRecorder = CleanupRequestRecorder()
    ) -> NativeSSHConnectionBroker {
        NativeSSHConnectionBroker(
            sharingOptions: sharingOptions,
            clock: RecordingImmediateClock(),
            jitterMilliseconds: { 200 },
            cleanupLauncher: { request in cleanupRecorder.requests.append(request) }
        )
    }

    private func pendingConnectionAttemptCount(
        in broker: NativeSSHConnectionBroker,
        for configuration: WorkspaceRemoteConfiguration
    ) -> Int {
        guard let key = NativeSSHConnectionKey(
            configuration: configuration,
            sharingOptions: sharingOptions
        ) else { return 0 }
        return broker.attemptStates[key]?.waiters.count ?? 0
    }

    private func configuration(
        owner: UUID,
        destination: String = "alice@example.test",
        port: Int? = nil,
        sshOptions: [String]? = nil,
        relayPort: Int? = 64_001,
        relayToken: String = "token"
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: destination,
            port: port,
            identityFile: nil,
            sshOptions: sshOptions ?? resolvedOwnedSSHOptions,
            localProxyPort: nil,
            relayPort: relayPort,
            relayID: "relay-id",
            relayToken: relayToken,
            localSocketPath: "/tmp/cmux-test.sock",
            ownerWorkspaceID: owner,
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true,
            persistentDaemonSlot: "ssh-test"
        )
    }
}
