import Foundation
import Synchronization
import Testing
@testable import CmuxNextDaemon

/// Records every sleep. Short sleeps (retry spacing) return at once; long
/// ones (a "stayed healthy" deadline) wait until cancelled, so a test sees
/// the retry spacing a real clock would produce.
final class RecordingClock: Clock, @unchecked Sendable {
    typealias Duration = Swift.Duration
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    let longSleep: Swift.Duration
    private let recorded = Mutex<[Swift.Duration]>([])
    init(longSleep: Swift.Duration = .seconds(5)) { self.longSleep = longSleep }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Swift.Duration { .zero }
    /// Durations of the short sleeps, in order.
    var sleeps: [Swift.Duration] { recorded.withLock { $0 } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        try Task.checkCancellation()
        let duration = deadline.offset
        guard duration < longSleep else {
            // Suspends until cancelled.
            let never = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { _ in }
            for await _ in never {}
            throw CancellationError()
        }
        recorded.withLock { $0.append(duration) }
        await Task.yield()
    }
}

/// Lets background loops run, then returns (tests only).
func settle(_ rounds: Int = 20_000) async {
    for _ in 0..<rounds { await Task.yield() }
}

/// Retry loops must not storm: every retry after a failure is spaced by a
/// capped backoff that keeps growing across consecutive failures, and timed
/// retries stop after a budget (later ones wait for an event). Before, a
/// dead daemon was re-`ensure`d (a process spawn) every 2 s forever, a
/// daemon that dropped every connection right after the handshake was
/// reconnected at 50 ms spacing (~20 Hz), and a failing first connect or
/// snapshot retried forever.
@Suite(.timeLimit(.minutes(1))) struct RetryStormTests {
    @Test func reconnectToAnUnreachableDaemonStopsTimedRetriesAfterItsBudget() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let calls = Mutex(0)
        let connection = DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil),
                                          clock: ImmediateClock()) {
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            if call == 1 { return DaemonEndpoint(socketPath: server.path) }
            throw DaemonError.launchFailed("exit 1: daemon down")
        }
        try await connection.start()
        server.disconnectClient()
        await settle()
        let attempts = calls.withLock { $0 } - 1
        #expect(attempts > 0)
        #expect(attempts <= 12, "reconnect kept re-running `server ensure` without an event: \(attempts) attempts")
        await connection.close()
    }

    @Test func aFlappingDaemonBacksOffInsteadOfReconnectingAtFullRate() async throws {
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { _, _ in [] })
        defer { server.stop() }
        let clock = RecordingClock()
        let connection = DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil),
                                          clock: clock) { DaemonEndpoint(socketPath: server.path) }
        try await connection.start()
        for _ in 0..<5 {
            while !(await connection.isReady) { await Task.yield() }
            // The daemon accepts the handshake and drops the connection at
            // once. Repeat until the drop is seen: on a loaded machine the
            // server can publish the new client's descriptor after the
            // connection already reports ready, and one disconnect then
            // closed nothing (the test hung).
            while await connection.isReady {
                server.disconnectClient()
                await Task.yield()
            }
        }
        while !(await connection.isReady) { await Task.yield() }
        let spacing = clock.sleeps
        #expect(spacing.count >= 5)
        #expect(zip(spacing, spacing.dropFirst()).allSatisfy { $0 < $1 },
                "reconnect spacing did not grow across consecutive drops: \(spacing)")
        await connection.close()
    }

    @Test func firstConnectStopsTimedRetriesAfterItsBudget() async {
        let attempts = Mutex(0)
        let task = Task {
            await DaemonStartup.connect(clock: ImmediateClock()) {
                DaemonConnection(configuration: DaemonConnection.Configuration(terminalEnvironment: nil)) {
                    attempts.withLock { $0 += 1 }
                    throw DaemonError.launchFailed("exit 1: the detached session owner did not become ready")
                }
            } onFailure: { _ in }
        }
        await settle()
        let count = attempts.withLock { $0 }
        task.cancel()
        _ = await task.value
        #expect(count <= 12, "first connect re-ran `server ensure` without an event: \(count) attempts")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ResyncStormTests {
    @Test func aSnapshotThatKeepsFailingStopsRetryingAfterItsBudget() async throws {
        let snapshots = Mutex(0)
        let server = try FakeDaemonServer(handler: ConnectionTests.handshake { request, id in
            if request["cmd"]?.stringValue == "list-workspaces" {
                snapshots.withLock { $0 += 1 }
                return [#"{"id":\#(id),"ok":false,"error":{"code":"busy","message":"busy"}}"#]
            }
            return [#"{"id":\#(id),"ok":true,"data":{}}"#]
        })
        defer { server.stop() }
        let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: server.path))
        let store = DaemonStore()
        store.resyncClock = ImmediateClock()
        _ = try await connection.start()
        let run = Task { await store.run(connection: connection) }
        defer { run.cancel() }
        // Enough time for a storm to show; the budget is spent long before.
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, snapshots.withLock({ $0 }) < 200 {
            await Task.yield()
        }
        let count = snapshots.withLock { $0 }
        #expect(count <= 12, "a failing snapshot was retried without an event: \(count) snapshots")
        await connection.close()
    }
}
