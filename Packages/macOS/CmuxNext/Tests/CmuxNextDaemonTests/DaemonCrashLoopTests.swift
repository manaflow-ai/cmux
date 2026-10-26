import CmuxNextWakeups
import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// plans/cmux-next/idle-wakeups.md section 8: a daemon that is relaunched and
/// dies each time a client reaches it. Every relaunch makes a new socket, a
/// real event, so the reconnect loop retried at once and only launch time
/// limited it. The test plays the relauncher (launchd's KeepAlive): it kills
/// each daemon as soon as the connection reaches it, then starts the next.
/// The connection's clock never runs, so only those socket changes and an
/// explicit event can wake its reconnect loop.
@Suite(.enabled(if: RealBinary.url != nil, "no cmux-tui binary available"), .liveDaemon)
struct DaemonCrashLoopTests {
    @Test func aDaemonThatDiesOnEveryConnectIsRetriedABoundedNumberOfTimes() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-crash-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let environment = LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:])
        let launcher = DaemonLauncher(
            work: BackgroundWork(label: "test.daemon-launcher"),
            configuration: .init(binary: binary, session: "cnd-crash-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { environment })
        _ = try await launcher.ensure()
        let wake = RetryWake(owner: "DaemonCrashLoopTests")
        let connection = DaemonConnection(configuration: .init(retryWake: wake), clock: StoppedClock(),
                                          endpointProvider: launcher.endpointProvider)
        var current = try await connection.start().pid
        var reconnects = 0
        for _ in 0..<10 {
            kill(current, SIGKILL)
            // The connection notes the drop first, so the next socket is a change after its failure.
            try await Task.sleep(for: .seconds(1))
            _ = try await launcher.ensure()
            guard let next = await Self.reached(connection, otherThan: current, within: .seconds(10)) else { break }
            reconnects += 1
            current = next
        }
        #expect(reconnects <= 3, "each new socket of a crash loop reconnected at once (\(reconnects) times)")

        // Once the loop stopped, an explicit event (app activation, a reconnect action) still reconnects.
        var resumed: Int32?
        if reconnects < 10 {
            wake.fire()
            resumed = await Self.reached(connection, otherThan: current, within: .seconds(20))
            #expect(resumed != nil, "an explicit event did not reconnect after the crash loop")
        }
        await BranchDaemonHarness.shutDown(connection)
        if reconnects < 10, resumed == nil, let running = await launcher.runningOwner() { kill(running.pid, SIGKILL) }
    }

    /// The pid of the daemon the connection reached once it is not `pid`, or nil after `within`.
    private static func reached(_ connection: DaemonConnection, otherThan pid: Int32, within: Duration) async -> Int32? {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline {
            if let current = await connection.identity?.pid, current != pid { return current }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }
}

/// A clock whose time never passes: no timed retry or health timer fires.
private struct StoppedClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { Instant(offset: .zero) }
    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
}
