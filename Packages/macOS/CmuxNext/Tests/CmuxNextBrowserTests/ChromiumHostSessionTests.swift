@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Observation
import Testing

/// The Chromium host session's lifecycle without Chromium: a stand-in
/// launcher hands out socket pairs, and the test plays the host on the other
/// end. A host that ends (a CHECK, a crash, a kill) restarts once with the
/// page's last committed URL; a host that ends again within the safe-restart
/// window stays ended; a host closed on purpose does not restart.
@MainActor
@Suite struct ChromiumHostSessionTests {
    /// One stand-in host: the test's end of the wire.
    nonisolated struct FakeHost: Sendable {
        let pid: pid_t
        let wire: ChromiumHostConnection
    }

    // Test double shared by the session (any thread) and the test; every field
    // is behind `state`'s lock.
    nonisolated final class FakeLauncher: ChromiumHostLaunching, @unchecked Sendable {
        private struct State {
            var hosts: [FakeHost] = []
            var exits: [pid_t: CheckedContinuation<ChromiumHostExit, Never>] = [:]
            var pending: [pid_t: ChromiumHostExit] = [:]
            var launched: AsyncStream<FakeHost>.Continuation?
        }
        private let state = Mutex(State())
        let launches: AsyncStream<FakeHost>

        init() {
            let (stream, continuation) = AsyncStream<FakeHost>.makeStream()
            launches = stream
            state.withLock { $0.launched = continuation }
        }

        var count: Int { state.withLock { $0.hosts.count } }

        func launch(executable: URL, arguments: [String]) throws -> ChromiumHostProcessHandle {
            var toHost: [Int32] = [-1, -1]
            var fromHost: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &toHost) == 0, socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0 else {
                throw ChromiumHostLauncher.LaunchError.socketPair(errno)
            }
            let host = state.withLock { state -> FakeHost in
                let host = FakeHost(pid: pid_t(1_000 + state.hosts.count),
                                    wire: ChromiumHostConnection(readFD: toHost[1], writeFD: fromHost[1]))
                state.hosts.append(host)
                return host
            }
            state.withLock { $0.launched }?.yield(host)
            return ChromiumHostProcessHandle(pid: host.pid, readFD: fromHost[0], writeFD: toHost[0])
        }

        func exit(of pid: pid_t) async -> ChromiumHostExit {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state -> ChromiumHostExit? in
                    if let exit = state.pending.removeValue(forKey: pid) { return exit }
                    state.exits[pid] = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }

        func reap(_ pid: pid_t) {}

        /// The host process `host` ends: its wire closes, then its exit is reported.
        func end(_ host: FakeHost, _ exit: ChromiumHostExit) {
            host.wire.close()
            let waiter = state.withLock { state -> CheckedContinuation<ChromiumHostExit, Never>? in
                guard let waiter = state.exits.removeValue(forKey: host.pid) else {
                    state.pending[host.pid] = exit
                    return nil
                }
                return waiter
            }
            waiter?.resume(returning: exit)
        }
    }

    /// A clock the test moves.
    final class TestClock {
        var now = ContinuousClock.now
    }

    private static let configuration = ChromiumHostConfiguration(executable: URL(filePath: "/nonexistent"), arguments: [])

    /// Waits until `condition` holds; re-evaluated only when an observed
    /// property it read changes, bounded by `timeout`.
    private func until(_ what: String, timeout: Duration = .seconds(10), _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            let (changed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let holds = withObservationTracking(condition) {
                signal.yield()
                signal.finish()
            }
            if holds { return }
            let remaining = deadline - .now
            guard remaining > .zero else {
                Issue.record("timed out: \(what)")
                throw CancellationError()
            }
            let didChange = await withTaskGroup(of: Bool.self) { group in
                group.addTask { for await _ in changed { return true }; return false }
                group.addTask {
                    try? await Task.sleep(for: remaining) // bound of a test wait, not a synchronization
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !didChange, !condition() {
                Issue.record("timed out: \(what)")
                throw CancellationError()
            }
        }
    }

    private func nextLaunch(_ launcher: FakeLauncher) async throws -> FakeHost {
        var iterator = launcher.launches.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private func firstFrame(of host: FakeHost) async throws -> ChromiumHostFrame {
        var iterator = host.wire.frames.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private func answer(_ host: FakeHost, context: Int32, address: String) {
        host.wire.send(ChromiumHostFrame(.ready, v: [27, host.pid]))
        host.wire.send(ChromiumHostFrame(.context, v: [context]))
        host.wire.send(ChromiumHostFrame(.address, payload: Array(address.utf8)))
    }

    @Test func aHostThatEndsRestartsWithTheSavedPage() async throws {
        let launcher = FakeLauncher()
        let clock = TestClock()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { clock.now })
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        let opened = try await firstFrame(of: first)
        #expect(opened.kind == .navigate)
        #expect(opened.text == "https://a.example/")
        answer(first, context: 77, address: "https://b.example/")
        try await until("running with context 77 at b") {
            session.phase == .running && session.contextID == 77 && session.url == "https://b.example/"
        }

        clock.now += .seconds(5)
        launcher.end(first, ChromiumHostExit(signal: SIGTRAP, status: nil))  // a Chromium CHECK
        let second = try await nextLaunch(launcher)
        let reopened = try await firstFrame(of: second)
        #expect(reopened.text == "https://b.example/")
        #expect(session.restarts == 1)
        #expect(session.exits == ["signal 5"])
        // No pixels of the dead host stay on screen.
        #expect(session.contextID == 0)
        #expect(session.view.contextID == 0)
        #expect(session.phase == .starting)
    }

    @Test func aHostThatEndsAgainSoonStaysEnded() async throws {
        let launcher = FakeLauncher()
        let clock = TestClock()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { clock.now })
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        launcher.end(first, ChromiumHostExit(signal: SIGKILL, status: nil))
        let second = try await nextLaunch(launcher)
        clock.now += .seconds(10)
        launcher.end(second, ChromiumHostExit(signal: SIGSEGV, status: nil))
        try await until("ended") {
            if case .ended = session.phase { return true }
            return false
        }
        #expect(launcher.count == 2)
        #expect(session.restarts == 1)

        // The person reloads: a new host starts.
        session.open("https://a.example/")
        _ = try await nextLaunch(launcher)
        #expect(launcher.count == 3)
    }

    @Test func aHostClosedOnPurposeDoesNotRestart() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        answer(host, context: 5, address: "https://a.example/")
        try await until("running") { session.phase == .running }
        session.close()
        var frames = host.wire.frames.makeAsyncIterator()
        var sawQuit = false
        while let frame = await frames.next() {
            if frame.kind == .quit {
                sawQuit = true
                break
            }
        }
        #expect(sawQuit)
        launcher.end(host, ChromiumHostExit(signal: nil, status: 0))
        try await until("idle") { session.phase == .idle }
        #expect(launcher.count == 1)
    }

    @Test func restartPolicy() {
        let policy = ChromiumHostRestartPolicy()
        #expect(policy.restarts(ranFor: .seconds(1), isFirstStart: true))
        #expect(!policy.restarts(ranFor: .seconds(59), isFirstStart: false))
        #expect(policy.restarts(ranFor: .seconds(60), isFirstStart: false))
    }
}
