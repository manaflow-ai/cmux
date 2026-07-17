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

        broker.retainWorkspace(first)
        broker.retainWorkspace(second)
        broker.releaseWorkspace(first)
        #expect(recorder.requests.isEmpty)

        broker.releaseWorkspace(second)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].arguments.contains(resolvedOwnedSSHOptions[2]))
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

        broker.retainWorkspace(custom)
        broker.releaseWorkspace(custom)

        #expect(recorder.requests.isEmpty)
    }

    @Test("A stale configuration cannot release its replacement lease")
    func staleConfigurationCannotReleaseReplacement() {
        let recorder = CleanupRequestRecorder()
        let broker = makeBroker(cleanupRecorder: recorder)
        let owner = UUID()
        let original = configuration(owner: owner, relayPort: 64_001, relayToken: "old")
        let replacement = configuration(owner: owner, relayPort: 64_002, relayToken: "new")

        broker.retainWorkspace(original)
        broker.retainWorkspace(replacement)
        broker.releaseWorkspace(original)
        #expect(recorder.requests.isEmpty)

        broker.releaseWorkspace(replacement)
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

        broker.retainWorkspace(original)
        broker.retainWorkspace(replacement)
        #expect(recorder.requests.isEmpty)

        broker.releaseWorkspace(original)
        #expect(recorder.requests.count == 1)
        #expect(recorder.requests[0].arguments.contains(original.sshOptions[2]))

        broker.releaseWorkspace(replacement)
        #expect(recorder.requests.count == 2)
        #expect(recorder.requests[1].arguments.contains(replacement.sshOptions[2]))
    }

    @Test("Cleanup reuses the shared path without negotiating a replacement master")
    func cleanupArgumentsAreReuseOnly() {
        let configuration = configuration(owner: UUID(), port: 2222)
        let arguments = RemoteControlMasterCleanup().cleanupArguments(configuration: configuration)

        #expect(arguments.prefix(4) == ["-o", "BatchMode=yes", "-o", "ControlMaster=no"])
        #expect(arguments.contains("ControlPath=/tmp/cmux-ssh-501-%C"))
        #expect(!arguments.contains("ControlMaster=auto"))
        #expect(!arguments.contains("ControlPersist=600"))
        #expect(arguments.suffix(3) == ["-O", "exit", "alice@example.test"])
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
        #expect(broker.pendingConnectionAttemptCount(for: followerConfiguration) == 1)

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
        let first = configuration(owner: UUID(), destination: "alice@first.example.test")
        let second = configuration(owner: UUID(), destination: "alice@second.example.test")

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
        #expect(broker.pendingConnectionAttemptCount(for: configuration) == 1)

        follower.cancel()
        do {
            try await follower.value
            Issue.record("Expected the queued attempt to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }
        #expect(broker.pendingConnectionAttemptCount(for: configuration) == 0)

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
            sshOptions: sshOptions ?? sharingOptions.mergingDefaults(into: []),
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

@MainActor
private final class CleanupRequestRecorder {
    var requests: [NativeSSHControlMasterCleanupRequest] = []
}

private actor AsyncLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor AsyncEventLog {
    private(set) var values: [String] = []
    private var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ value: String) {
        values.append(value)
        let ready = countWaiters.filter { values.count >= $0.count }
        countWaiters.removeAll { values.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func waitForCount(_ count: Int) async {
        if values.count >= count { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }
}

private actor ManualBrokerClock: RemoteProxyRetryClock {
    private var requestedDelayWaiters: [CheckedContinuation<Int, Never>] = []
    private var unconsumedDelays: [Int] = []
    private var pendingSleeps: [CheckedContinuation<Void, any Error>] = []

    func sleep(forMilliseconds milliseconds: Int) async throws {
        if let waiter = requestedDelayWaiters.first {
            requestedDelayWaiters.removeFirst()
            waiter.resume(returning: milliseconds)
        } else {
            unconsumedDelays.append(milliseconds)
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingSleeps.append(continuation)
        }
    }

    func nextRequestedDelay() async -> Int {
        if !unconsumedDelays.isEmpty {
            return unconsumedDelays.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            requestedDelayWaiters.append(continuation)
        }
    }

    func resumeNextSleep() {
        guard !pendingSleeps.isEmpty else { return }
        pendingSleeps.removeFirst().resume()
    }
}

private actor RecordingImmediateClock: RemoteProxyRetryClock {
    private(set) var requestedDelays: [Int] = []

    func sleep(forMilliseconds milliseconds: Int) async throws {
        requestedDelays.append(milliseconds)
    }
}
