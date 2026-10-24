#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
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
        /// The descriptor `wire` writes to the session on, for raw writes.
        let toSessionFD: Int32
        /// The session's own ends of the wire (its read and write descriptors).
        let sessionFDs: [Int32]
    }

    /// Shared by the session (any thread) and the test: its mutable state is
    /// behind `state`'s lock, so it is `Sendable` as declared.
    nonisolated final class FakeLauncher: ChromiumHostLaunching, Sendable {
        private struct State {
            var hosts: [FakeHost] = []
            var exits: [pid_t: CheckedContinuation<ChromiumHostExit, Never>] = [:]
            var pending: [pid_t: ChromiumHostExit] = [:]
            var launched: AsyncStream<FakeHost>.Continuation?
            var waitingForExit: AsyncStream<pid_t>.Continuation?
            var killed: [pid_t] = []
        }
        private let state = Mutex(State())
        let launches: AsyncStream<FakeHost>
        /// The pid of each host whose exit the session waits for (``exit(of:)`` holds its continuation).
        let exitWaits: AsyncStream<pid_t>

        init() {
            let (stream, continuation) = AsyncStream<FakeHost>.makeStream()
            launches = stream
            let (waits, waiting) = AsyncStream<pid_t>.makeStream()
            exitWaits = waits
            state.withLock { state in
                state.launched = continuation
                state.waitingForExit = waiting
            }
        }

        var count: Int { state.withLock { $0.hosts.count } }
        var killed: [pid_t] { state.withLock { $0.killed } }

        func launch(executable: URL, arguments: [String]) throws -> ChromiumHostProcessHandle {
            var toHost: [Int32] = [-1, -1]
            var fromHost: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &toHost) == 0, socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0 else {
                throw ChromiumHostLauncher.LaunchError.socketPair(errno)
            }
            let host = state.withLock { state -> FakeHost in
                let host = FakeHost(pid: pid_t(1_000 + state.hosts.count),
                                    wire: ChromiumHostConnection(readFD: toHost[1], writeFD: fromHost[1]),
                                    toSessionFD: fromHost[1], sessionFDs: [fromHost[0], toHost[0]])
                state.hosts.append(host)
                return host
            }
            state.withLock { $0.launched }?.yield(host)
            return ChromiumHostProcessHandle(pid: host.pid, readFD: fromHost[0], writeFD: toHost[0])
        }

        func exit(of pid: pid_t) async -> ChromiumHostExit {
            await withCheckedContinuation { continuation in
                let (ready, waiting) = state.withLock { state -> (ChromiumHostExit?, AsyncStream<pid_t>.Continuation?) in
                    if let exit = state.pending.removeValue(forKey: pid) { return (exit, nil) }
                    state.exits[pid] = continuation
                    return (nil, state.waitingForExit)
                }
                if let ready { continuation.resume(returning: ready) }
                waiting?.yield(pid)
            }
        }

        func reap(_ pid: pid_t) {}

        /// A SIGKILL: the stand-in host ends with the signal.
        func kill(_ pid: pid_t) {
            let host = state.withLock { state -> FakeHost? in
                state.killed.append(pid)
                return state.hosts.first { $0.pid == pid }
            }
            if let host { end(host, ChromiumHostExit(signal: SIGKILL, status: nil)) }
        }

        /// The host process `host` ends: its wire closes, then its exit is reported.
        func end(_ host: FakeHost, _ exit: ChromiumHostExit) {
            host.wire.close()
            reportExit(host, exit)
        }

        /// Reports the exit of `host` and leaves its wire open (the kernel told
        /// cmux about the exit before cmux read the host's last bytes).
        func reportExit(_ host: FakeHost, _ exit: ChromiumHostExit) {
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

    /// Writes all of `bytes` to `fd`, blocking until the reader has made room.
    private func writeAll(_ bytes: [UInt8], to fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            offset += written
        }
    }

    // Before the fix the frames task applied these frames after hostEnded had
    // started the next host: phase .running and context 77 of a dead host.
    @Test(.timeLimit(.minutes(1))) func framesOfAHostThatEndedDoNotChangeTheNextHost() async throws {
        let launcher = FakeLauncher()
        var exitWaits = launcher.exitWaits.makeAsyncIterator()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        // The session waits for the host's exit, so its frames task (started first) waits
        // on the wire too: a frame from now on is handled in a main-actor job of its own.
        #expect(await exitWaits.next() == first.pid)

        // No await until nextLaunch: the main actor runs nothing else meanwhile. The
        // exit is reported first, so hostEnded is queued before any frame below.
        launcher.reportExit(first, ChromiumHostExit(signal: SIGSEGV, status: nil))
        var stale = ChromiumHostFrame(.ready, v: [27, first.pid]).encoded()
        stale += ChromiumHostFrame(.context, v: [77]).encoded()
        // Far more bytes than the socket holds (ChromiumHostConnection.sendBuffer): the
        // write returns only after the session's reader took the ready and context
        // frames (and some of these) into its stream, still unhandled.
        let filler = ChromiumHostFrame(.address, payload: [UInt8](repeating: UInt8(ascii: "x"),
                                                                 count: ChromiumHostFrame.maxPayload)).encoded()
        for _ in 0..<16 { stale += filler }
        _ = fcntl(first.toSessionFD, F_SETFL, fcntl(first.toSessionFD, F_GETFL) & ~O_NONBLOCK)
        try writeAll(stale, to: first.toSessionFD)
        first.wire.close()

        let second = try await nextLaunch(launcher)
        let reopened = try await firstFrame(of: second)
        #expect(reopened.text == "https://a.example/")
        #expect(session.phase == .starting)
        #expect(session.contextID == 0)
        #expect(session.view.contextID == 0)
        #expect(session.forkAPI == 0)
        #expect(session.url == "https://a.example/")
        #expect(session.exits == ["signal \(SIGSEGV)"])
    }

    // Before the fix a host that could not start was started once more (the first
    // start's restart) and failed the same way.
    @Test(arguments: [Int32(64), 65, 66, 67])
    func aHostThatCannotStartStaysEnded(status: Int32) async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        launcher.end(host, ChromiumHostExit(signal: nil, status: status))
        try await until("ended") {
            if case .ended = session.phase { return true }
            return false
        }
        guard case .ended(let reason) = session.phase else { return }
        #expect(reason.contains("could not start (exit \(status))"))
        #expect(session.restarts == 0)
        #expect(launcher.count == 1)
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

    /// Reads the host's frames until one of `kind`; nil when the wire ends first.
    /// A local iterator, as ``nextLaunch(_:)`` does: a stream is read by one iterator at a time, so
    /// sequential calls continue where the last one stopped.
    private func frame(_ kind: ChromiumHostFrame.Kind, in stream: AsyncStream<ChromiumHostFrame>) async -> ChromiumHostFrame? {
        var frames = stream.makeAsyncIterator()
        while let frame = await frames.next() {
            if frame.kind == kind { return frame }
        }
        return nil
    }

    @Test func aHostThatIgnoresQuitIsKilledAtTheQuitLimit() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now },
                                          quitLimit: .milliseconds(20))
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        answer(host, context: 5, address: "https://a.example/")
        try await until("running") { session.phase == .running }
        session.close()
        // The host's UI thread hangs: it never acts on quit and never exits by itself.
        try await until("idle after the deadline's SIGKILL") { session.phase == .idle }
        #expect(launcher.killed == [host.pid])
        #expect(session.exits == ["signal \(SIGKILL)"])
        #expect(launcher.count == 1)
    }

    @Test func openWhileTheHostQuitsStartsANewHostAfterItEnds() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        answer(first, context: 5, address: "https://a.example/")
        try await until("running") { session.phase == .running }
        session.close()
        session.open("https://b.example/")
        _ = try #require(await frame(.quit, in: first.wire.frames))
        launcher.end(first, ChromiumHostExit(signal: nil, status: 0))
        // The quitting host never got the navigation; it went to a fresh host, not a crash restart.
        #expect(await frame(.navigate, in: first.wire.frames) == nil)
        let second = try await nextLaunch(launcher)
        let opened = try await firstFrame(of: second)
        #expect(opened.kind == .navigate)
        #expect(opened.text == "https://b.example/")
        #expect(session.restarts == 0)
        #expect(session.phase == .starting)
    }

    // Before the fix the quitting host's last address (its committed page, sent after the reopen)
    // replaced the URL the reopen asked for, and the new host loaded the old page (seen on aws-m4pro,
    // macOS 27, as a flaky openWhileTheHostQuitsStartsANewHostAfterItEnds).
    @Test(.timeLimit(.minutes(1))) func anAddressFromAHostThatQuitsDoesNotReplaceTheReopenedURL() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        answer(first, context: 5, address: "https://a.example/")
        try await until("a shown") { session.phase == .running && session.url == "https://a.example/" }
        session.close()
        session.open("https://b.example/")
        // The quitting host still reports its committed page.
        first.wire.send(ChromiumHostFrame(.address, payload: Array("https://a.example/".utf8)))
        // A round trip after it: frames are handled in order, so the address was handled when the pong is.
        let ping = Task { await session.ping(count: 1) }
        var frames = first.wire.frames.makeAsyncIterator()
        var sawQuit = false
        var request: ChromiumHostFrame?
        while request == nil, let frame = await frames.next() {
            if frame.kind == .quit { sawQuit = true }
            if frame.kind == .ping { request = frame }
        }
        let sent = try #require(request)
        #expect(sawQuit)
        var pong = ChromiumHostFrame(.pong, t0: sent.t0)
        pong.seq = sent.seq
        first.wire.send(pong)
        #expect(await ping.value.count == 1)
        #expect(session.url == "https://b.example/")
        launcher.end(first, ChromiumHostExit(signal: nil, status: 0))
        let second = try await nextLaunch(launcher)
        let opened = try await firstFrame(of: second)
        #expect(opened.kind == .navigate)
        #expect(opened.text == "https://b.example/")
    }

    @Test func aURLLongerThanAFrameIsRefusedWithoutAHost() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        let long = "data:text/plain," + String(repeating: "a", count: ChromiumHostFrame.maxPayload)
        #expect(!session.open(long))
        #expect(launcher.count == 0)
        #expect(session.phase == .idle)
        #expect(session.url.isEmpty)
        #expect(session.lastError?.contains("URL longer than") == true)
    }

    // Before the fix the waits ignored cancellation and this hung: the limit turns that into a failure.
    @Test(.timeLimit(.minutes(1))) func aCancelledPingOrStatsRequestReturnsAtOnce() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        answer(host, context: 5, address: "https://a.example/")
        try await until("running") { session.phase == .running }
        // The host never answers: only cancellation ends these waits.
        let ping = Task { await session.ping(count: 1) }
        let stats = Task { await session.hostInputStats() }
        // Both requests are on the wire, so both waiters are registered. The wire also carries the
        // session's start frames (navigate, ...): wait for the two requests among them.
        let requests: Set<ChromiumHostFrame.Kind> = [.ping, .stats]
        var seen: Set<ChromiumHostFrame.Kind> = []
        var frames = host.wire.frames.makeAsyncIterator()
        while !seen.isSuperset(of: requests), let frame = await frames.next() {
            if let kind = frame.kind { seen.insert(kind) }
        }
        try #require(seen.isSuperset(of: requests))
        ping.cancel()
        stats.cancel()
        #expect(await ping.value.isEmpty)
        #expect(await stats.value == nil)
    }

    @Test(.timeLimit(.minutes(1))) func aStatsReplyAnswersTheRequestWithItsSeq() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        answer(host, context: 5, address: "https://a.example/")
        try await until("running") { session.phase == .running }
        let stats = Task { await session.hostInputStats() }
        let request = try #require(await frame(.stats, in: host.wire.frames))
        var stale = ChromiumHostFrame(.statsReply, v: [1])
        stale.seq = request.seq &+ 1  // another request's reply
        host.wire.send(stale)
        var reply = ChromiumHostFrame(.statsReply, v: [7, 1, 2, 3, 4, 0])
        reply.seq = request.seq
        host.wire.send(reply)
        #expect(await stats.value?["events"] == 7)
    }

    /// The file a descriptor names (device and inode), or nil when it is closed.
    private static func identity(of fd: Int32) -> [UInt64]? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return [UInt64(bitPattern: Int64(info.st_dev)), info.st_ino]
    }

    // The close path frees everything the host had in cmux: both descriptors and the reader thread
    // (a connection dropped without close() is ChromiumHostProcessTests.aConnectionDroppedWithoutCloseEndsTheWire).
    @Test(.timeLimit(.minutes(1))) func aClosedSessionFreesItsReaderThreadAndDescriptors() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher, now: { ContinuousClock.now })
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        let opened = host.sessionFDs.map(Self.identity(of:))
        #expect(opened.allSatisfy { $0 != nil })
        answer(host, context: 5, address: "https://a.example/")
        try await until("running") { session.phase == .running }
        session.close()
        _ = try #require(await frame(.quit, in: host.wire.frames))
        launcher.end(host, ChromiumHostExit(signal: nil, status: 0))
        try await until("idle") { session.phase == .idle }
        // The reader thread closes its descriptor as its last step before it returns, so a closed
        // read descriptor means the thread has ended. No signal crosses from that thread to the test:
        // this checks each 10 ms, bounded by the test's limit.
        let deadline = ContinuousClock.now + .seconds(10)
        var stillOpen = host.sessionFDs
        while !stillOpen.isEmpty, ContinuousClock.now < deadline {
            // A number the system gave to another file since (another test) is closed for this check.
            stillOpen = zip(host.sessionFDs, opened).filter { fd, was in Self.identity(of: fd) == was }.map(\.0)
            if !stillOpen.isEmpty { try await Task.sleep(for: .milliseconds(10)) } // bound of a test wait
        }
        #expect(stillOpen.isEmpty)
    }

    @Test func restartPolicy() {
        let policy = ChromiumHostRestartPolicy()
        #expect(policy.restarts(ranFor: .seconds(1), isFirstStart: true))
        #expect(!policy.restarts(ranFor: .seconds(59), isFirstStart: false))
        #expect(policy.restarts(ranFor: .seconds(60), isFirstStart: false))
    }
}
#endif
