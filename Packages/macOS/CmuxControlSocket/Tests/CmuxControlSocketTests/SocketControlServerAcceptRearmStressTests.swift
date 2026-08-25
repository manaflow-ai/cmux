import CmuxSettings
import Darwin
import Foundation
import os
import Testing

@_spi(CmuxControlSocketTesting) @testable import CmuxControlSocket

private struct RecordedRearm: Sendable {
    let generation: UInt64
    let errnoCode: Int32
    let consecutiveFailures: Int
    let delayMs: Int
}

private struct RecordedRearmBreadcrumb: Sendable {
    let message: String
    let listenerState: String?
    let errnoCode: Int?
    let pendingRearmGeneration: UInt64?
    let delayMs: Int?
}

private final class AcceptRearmRecorder: Sendable {
    private struct State {
        var breadcrumbs: [RecordedRearmBreadcrumb] = []
        var rearms: [RecordedRearm] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let rearmRequests: AsyncStream<RecordedRearm>
    private let rearmRequestsContinuation: AsyncStream<RecordedRearm>.Continuation

    init() {
        let stream = AsyncStream<RecordedRearm>.makeStream(bufferingPolicy: .unbounded)
        rearmRequests = stream.stream
        rearmRequestsContinuation = stream.continuation
    }

    var breadcrumbs: [RecordedRearmBreadcrumb] {
        state.withLock { $0.breadcrumbs }
    }

    var rearms: [RecordedRearm] {
        state.withLock { $0.rearms }
    }

    func makeEvents() -> SocketControlServerEvents {
        SocketControlServerEvents(
            breadcrumb: { message, data in
                let breadcrumb = RecordedRearmBreadcrumb(
                    message: message,
                    listenerState: data["listenerState"] as? String,
                    errnoCode: data["errno"] as? Int,
                    pendingRearmGeneration: data["pendingRearmGeneration"] as? UInt64,
                    delayMs: data["rearmDelayMs"] as? Int
                )
                self.state.withLock { $0.breadcrumbs.append(breadcrumb) }
            },
            failure: { _, _, _, _ in },
            listenerDidStart: { _, _ in },
            recordLastSocketPath: { _ in },
            pathMissingDetected: { _, _ in },
            rearmRequested: { generation, errnoCode, consecutiveFailures, delayMs in
                let rearm = RecordedRearm(
                    generation: generation,
                    errnoCode: errnoCode,
                    consecutiveFailures: consecutiveFailures,
                    delayMs: delayMs
                )
                self.state.withLock { $0.rearms.append(rearm) }
                self.rearmRequestsContinuation.yield(rearm)
            }
        )
    }
}

@MainActor
private struct AcceptRearmHarness: ~Copyable {
    let directory: URL
    let socketPath: String
    let recorder: AcceptRearmRecorder
    let server: SocketControlServer

    init(clock: TestSocketRecoveryClock, policy: SocketListenerPolicy) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("accept-rearm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("cmux.sock").path
        recorder = AcceptRearmRecorder()
        server = SocketControlServer(
            initialSocketPath: socketPath,
            listenerPolicy: policy,
            recoveryClock: clock,
            notificationCenter: NotificationCenter(),
            events: recorder.makeEvents()
        )
    }

    func shutdown() {
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct UnixConnectAttempt: Sendable {
    let connected: Bool
    let errnoCode: Int32
}

private func connectAttempt(to path: String) -> UnixConnectAttempt {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        return UnixConnectAttempt(connected: false, errnoCode: errno)
    }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let copied = path.withCString { source -> Bool in
        let length = strlen(source)
        guard length < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.baseAddress?.copyMemory(from: source, byteCount: length + 1)
        }
        return true
    }
    guard copied else {
        return UnixConnectAttempt(connected: false, errnoCode: ENAMETOOLONG)
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.connect(fd, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    let connectErrno = result == 0 ? 0 : errno
    return UnixConnectAttempt(connected: result == 0, errnoCode: connectErrno)
}

private func concurrentConnectBurst(to path: String, count: Int) async -> [UnixConnectAttempt] {
    await withTaskGroup(of: UnixConnectAttempt.self) { group in
        for _ in 0..<count {
            group.addTask {
                connectAttempt(to: path)
            }
        }
        var attempts: [UnixConnectAttempt] = []
        attempts.reserveCapacity(count)
        for await attempt in group {
            attempts.append(attempt)
        }
        return attempts
    }
}

@MainActor
private func waitForRearmCondition(
    attempts: Int = 1_000,
    _ predicate: () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

@MainActor
private func driveBackoffFailure(
    server: SocketControlServer,
    listenerSocket: Int32,
    generation: UInt64,
    clock: TestSocketRecoveryClock
) async {
    server.handleAcceptFailure(
        listenerSocket: listenerSocket,
        generation: generation,
        errnoCode: EMFILE
    )
    let didSchedule = await waitForRearmCondition { clock.pendingSleepCount == 1 }
    #expect(didSchedule)
    clock.advance()
    let didResume = await waitForRearmCondition {
        let sourceSuspended = server.withListenerState { $0.listenerReadSourceSuspended }
        let recoveryHopInFlight = server.acceptRecovery.withLock {
            $0.generation == generation && $0.recoveryHopInFlight
        }
        return clock.pendingSleepCount == 0
            && !sourceSuspended
            && !recoveryHopInFlight
    }
    #expect(didResume)
}

@MainActor
@Suite("SocketControlServer accept rearm stress")
struct SocketControlServerAcceptRearmStressTests {
    @Test func exactPathReportsRefusedDuringBoundedRearmAndRecoversAfterConcurrentHookBurst() async throws {
        let clock = TestSocketRecoveryClock()
        let policy = SocketListenerPolicy(
            acceptFailureBaseBackoffMs: 1,
            acceptFailureMaxBackoffMs: 8,
            acceptFailureMinimumRearmDelayMs: 8,
            acceptFailureRearmThreshold: 3
        )
        let harness = try AcceptRearmHarness(clock: clock, policy: policy)
        defer { harness.shutdown() }
        let server = harness.server
        let recorder = harness.recorder
        #expect(server.start(socketPath: harness.socketPath, accessMode: .cmuxOnly))

        let initial = server.listenerStateSnapshot()
        #expect(initial.serverSocket >= 0)
        #expect(initial.activeGeneration > 0)

        let hostRecovery = Task { @MainActor in
            var rearmIterator = recorder.rearmRequests.makeAsyncIterator()
            guard let rearm = await rearmIterator.next() else { return false }
            do {
                try await clock.sleep(forMilliseconds: rearm.delayMs)
            } catch {
                return false
            }
            guard let restartPath = server.claimPendingRearm(
                generation: rearm.generation,
                errnoCode: rearm.errnoCode,
                consecutiveFailures: rearm.consecutiveFailures,
                delayMs: rearm.delayMs
            ) else { return false }

            server.stop(cleanupDiscoveryState: false)
            return server.start(
                socketPath: restartPath,
                accessMode: .cmuxOnly,
                preserveAcceptFailureStreak: true
            )
        }
        defer { hostRecovery.cancel() }

        await driveBackoffFailure(
            server: server,
            listenerSocket: initial.serverSocket,
            generation: initial.activeGeneration,
            clock: clock
        )
        await driveBackoffFailure(
            server: server,
            listenerSocket: initial.serverSocket,
            generation: initial.activeGeneration,
            clock: clock
        )
        server.handleAcceptFailure(
            listenerSocket: initial.serverSocket,
            generation: initial.activeGeneration,
            errnoCode: EMFILE
        )

        let didEnterRearm = await waitForRearmCondition {
            server.hasPendingAcceptLoopRearm
                && recorder.rearms.count == 1
                && clock.pendingSleepCount == 1
        }
        #expect(didEnterRearm)
        let rearm = try #require(recorder.rearms.first)
        #expect(rearm.errnoCode == EMFILE)
        #expect(rearm.consecutiveFailures == 3)
        #expect(rearm.delayMs == 8)
        #expect(FileManager.default.fileExists(atPath: harness.socketPath))

        // Model the issue's 100 concurrent Codex hook connections against the
        // exact pinned path while the listener is parked for rearm.
        let burst = await concurrentConnectBurst(to: harness.socketPath, count: 100)
        #expect(burst.count == 100)
        #expect(burst.allSatisfy { !$0.connected && $0.errnoCode == ECONNREFUSED })

        let exactProbe = connectAttempt(to: harness.socketPath)
        #expect(!exactProbe.connected)
        #expect(exactProbe.errnoCode == ECONNREFUSED)

        let started = try #require(
            recorder.breadcrumbs.first { $0.message == "socket.listener.rearm.started" }
        )
        #expect(started.listenerState == "rearming")
        #expect(started.errnoCode == Int(EMFILE))
        #expect(started.pendingRearmGeneration == initial.activeGeneration)
        #expect(started.delayMs == 8)

        clock.advance()
        #expect(await hostRecovery.value)
        #expect(server.isRunning)
        #expect(connectAttempt(to: harness.socketPath).connected)

        let messages = recorder.breadcrumbs.map(\.message)
        let startedIndex = try #require(messages.firstIndex(of: "socket.listener.rearm.started"))
        let readyIndex = try #require(messages.firstIndex(of: "socket.listener.rearm.ready"))
        let completedIndex = try #require(messages.firstIndex(of: "socket.listener.rearm.completed"))
        #expect(startedIndex < readyIndex)
        #expect(readyIndex < completedIndex)
        #expect(!messages.contains("socket.listener.rearm.failed"))
    }
}
