#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Observation
import Testing

/// The Chromium host session's lifecycle without Chromium: a stand-in
/// launcher hands out socket pairs, and the test plays the host on the other
/// end. A host that ends (a CHECK, a crash, a kill) after its `ready` restarts
/// with the page's last committed URL until the crash budget is spent
/// (ChromiumHostRestartPolicyTests); a host that dies before its `ready` cannot
/// start and is not restarted; a host closed on purpose does not restart.
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

    static let configuration = ChromiumHostConfiguration(executable: URL(filePath: "/nonexistent"), arguments: [])

    /// Waits until `condition` holds; re-evaluated only when an observed
    /// property it read changes, bounded by `timeout`.
    func until(_ what: String, timeout: Duration = .seconds(10), _ condition: @escaping @MainActor () -> Bool) async throws {
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

    func nextLaunch(_ launcher: FakeLauncher) async throws -> FakeHost {
        var iterator = launcher.launches.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    func firstFrame(of host: FakeHost) async throws -> ChromiumHostFrame {
        var iterator = host.wire.frames.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    func answer(_ host: FakeHost, context: Int32, address: String) {
        host.wire.send(ChromiumHostFrame(.ready, v: [27, host.pid]))
        host.wire.send(ChromiumHostFrame(.context, v: [context]))
        host.wire.send(ChromiumHostFrame(.address, payload: Array(address.utf8)))
    }

    @Test func aHostThatEndsRestartsWithTheSavedPage() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        let opened = try await firstFrame(of: first)
        #expect(opened.kind == .navigate)
        #expect(opened.text == "https://a.example/")
        answer(first, context: 77, address: "https://b.example/")
        try await until("running with context 77 at b") {
            session.phase == .running && session.contextID == 77 && session.url == "https://b.example/"
        }

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

    /// While a host starts, restarts or has ended, the page view shows the theme's page background,
    /// not a hole onto whatever is behind the pane.
    @Test func thePageViewIsFilledWhileNoContextShows() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        let theme = PageBackground.cgColor(argb: PageBackground.themeARGB(in: session.view))
        #expect(session.view.backgroundFill == nil)
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        #expect(session.phase == .starting)
        #expect(session.view.backgroundFill == theme)
        answer(first, context: 77, address: "https://a.example/")
        try await until("running with context 77") { session.phase == .running && session.contextID == 77 }

        // A second host that dies before its ready cannot start: ended, with no context and the fill.
        launcher.end(first, ChromiumHostExit(signal: SIGTRAP, status: nil))
        let second = try await nextLaunch(launcher)
        #expect(session.view.contextID == 0)
        #expect(session.view.backgroundFill == theme)
        launcher.end(second, ChromiumHostExit(signal: SIGTRAP, status: nil))
        try await until("ended") {
            if case .ended = session.phase { return true }
            return false
        }
        #expect(session.view.contextID == 0)
        #expect(session.view.backgroundFill == theme)
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
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        // It said hello, so its end is a crash that restarts it (not a host that cannot start).
        first.wire.send(ChromiumHostFrame(.ready, v: [27, first.pid]))
        try await until("running") { session.phase == .running }
        // The session waits for the host's exit, so its frames task (started first) waits
        // on the wire too: a frame from now on is handled in a main-actor job of its own.
        #expect(await exitWaits.next() == first.pid)

        // No await until nextLaunch: the main actor runs nothing else meanwhile. The
        // exit is reported first, so hostEnded is queued before any frame below.
        launcher.reportExit(first, ChromiumHostExit(signal: SIGSEGV, status: nil))
        var stale = ChromiumHostFrame(.ready, v: [99, first.pid]).encoded()
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
        #expect(session.forkAPI == 27, "the stale ready (fork API 99) is not applied")
        #expect(session.url == "https://a.example/")
        #expect(session.exits == ["signal \(SIGSEGV)"])
    }

    // Before the fix a host that could not start was started once more (the first
    // start's restart) and failed the same way.
    @Test(arguments: [Int32(64), 65, 66, 67])
    func aHostThatCannotStartStaysEnded(status: Int32) async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
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

    // Before the fix a host that died before its ready was started again (the first start's
    // restart) and died the same way, and its reason never named the code signature check.
    @Test func aHostThatDiesBeforeItsReadyCannotStart() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher,
                                          signatureChecker: ChromiumHostRestartPolicyTests.Checker(.invalid(-67_061)))
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        launcher.end(host, ChromiumHostExit(signal: SIGKILL, status: nil))
        let checked = "could not start (signal \(SIGKILL)): it ended before Chromium started; "
            + "code signature invalid (OSStatus -67061)"
        try await until("ended with the signature check") { session.phase == .ended(checked) }
        #expect(session.restarts == 0)
        #expect(launcher.count == 1)
    }

    // Before the fix the second quick end already left the page ended: Chrome's budget allows 3.
    @Test func aHostThatSpendsTheCrashBudgetStaysEnded() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        session.open("https://a.example/")
        for crash in 1...ChromiumHostRestartPolicy.standardCrashLimit {
            let host = try await nextLaunch(launcher)
            answer(host, context: Int32(crash), address: "https://a.example/")
            try await until("running with context \(crash)") { session.phase == .running && session.contextID == UInt32(crash) }
            launcher.end(host, ChromiumHostExit(signal: SIGSEGV, status: nil))
        }
        try await until("ended") {
            if case .ended = session.phase { return true }
            return false
        }
        #expect(launcher.count == ChromiumHostRestartPolicy.standardCrashLimit)
        #expect(session.restarts == ChromiumHostRestartPolicy.standardCrashLimit - 1)

        // The person reloads: a new host starts.
        session.open("https://a.example/")
        _ = try await nextLaunch(launcher)
        #expect(launcher.count == ChromiumHostRestartPolicy.standardCrashLimit + 1)
    }

    @Test func aHostClosedOnPurposeDoesNotRestart() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
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

    /// The host launches off the main thread (task 037), so a close and a second open can come before it
    /// connects: the host still loads the last URL, then quits, and no second host starts.
    @Test func aCloseDuringTheLaunchQuitsTheHostOnceItConnects() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        session.open("https://a.example/")
        session.open("https://b.example/")
        session.close()
        #expect(session.phase == .starting)
        #expect(launcher.count == 0)
        let host = try await nextLaunch(launcher)
        let navigate = try await firstFrame(of: host)
        #expect(navigate.text == "https://b.example/")
        #expect(await frame(.quit, in: host.wire.frames) != nil)
        launcher.end(host, ChromiumHostExit(signal: nil, status: 0))
        try await until("idle") { session.phase == .idle }
        #expect(launcher.count == 1)
    }

    /// The presentation reports the session handed on (the app's input latency tracker), observed.
    @MainActor @Observable
    final class PresentedReports {
        var reports: [[UInt64]] = []
    }

    /// The host reports when each input's frame was presented: the session hands the event time
    /// and the presentation time on, in order, and keeps a frame that failed to present to itself.
    @Test func hostPresentationReportsReachTheInputLatencySeam() async throws {
        let launcher = FakeLauncher()
        let recorded = PresentedReports()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher,
                                          inputPresented: { event, presented in recorded.reports.append([event, presented]) })
        session.open("https://a.example/")
        let host = try await nextLaunch(launcher)
        answer(host, context: 5, address: "https://a.example/")
        host.wire.send(.inputPresented(.init(eventNanos: 1_000, presentedNanos: 9_000,
                                             feedbackFlags: ChromiumHostFrame.presentationFailed)))
        host.wire.send(.inputPresented(.init(eventNanos: 2_000, presentedNanos: 20_000, feedbackFlags: 1)))
        host.wire.send(.inputPresented(.init(eventNanos: 3_000, presentedNanos: 30_000, feedbackFlags: 1 | 1 << 2)))
        try await until("two reports") { recorded.reports.count == 2 }
        #expect(recorded.reports == [[2_000, 20_000], [3_000, 30_000]])
        #expect(session.report["input_presented_failed"] as? Int == 1)
    }

    /// Whether the current host reports presentation, as the session told the seam (the app's tracker), in order.
    @MainActor @Observable
    final class ReportsSeen {
        var values: [Bool] = []
    }

    /// The session tells the tracker whether page slots can expect a report: what the host's `ready` announced, and
    /// false once that host ended, so a page slot waits for a report only while one can come.
    @Test func theHostsReadyDecidesWhetherPageSlotsWaitForReports() async throws {
        let launcher = FakeLauncher()
        let seen = ReportsSeen()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher,
                                          reportsInputPresented: { seen.values.append($0) })
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        first.wire.send(ChromiumHostFrame(.ready, v: [27, first.pid, ChromiumHostFrame.readyReportsInputPresented]))
        try await until("the first host reports") { seen.values == [true] }
        launcher.end(first, ChromiumHostExit(signal: SIGTRAP, status: nil))
        let second = try await nextLaunch(launcher)
        #expect(seen.values == [true, false], "no report comes from a host that ended")
        answer(second, context: 5, address: "https://a.example/")  // an older host: no bit in its ready
        try await until("the second host does not report") { seen.values == [true, false, false] }
        #expect(session.phase == .running)
    }

    /// Reads the host's frames until one of `kind`; nil when the wire ends first.
    /// A local iterator, as ``nextLaunch(_:)`` does: a stream is read by one iterator at a time, so
    /// sequential calls continue where the last one stopped.
    func frame(_ kind: ChromiumHostFrame.Kind, in stream: AsyncStream<ChromiumHostFrame>) async -> ChromiumHostFrame? {
        var frames = stream.makeAsyncIterator()
        while let frame = await frames.next() {
            if frame.kind == kind { return frame }
        }
        return nil
    }

    @Test func aHostThatIgnoresQuitIsKilledAtTheQuitLimit() async throws {
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher,
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
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
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
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
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
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
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
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
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
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
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
        reply.t0 = (UInt64(2) << 32) | 3
        reply.t1 = 9
        host.wire.send(reply)
        let answered = await stats.value
        #expect(answered?["events"] == 7)
        #expect(answered?["coalesced"] == 9)
        #expect(answered?["activations"] == 2)
        #expect(answered?["key_windows"] == 3)
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
        let connections = Connections()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher,
                                          connected: { connections.all.append($0) })
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
        let connection = try #require(connections.all.first)
        #expect(connections.all.count == 1)
        // The reader thread closes its descriptor as its last step before it returns.
        await connection.readerEnded()
        // A number the system gave to another file since (another test) is closed for this check.
        let stillOpen = zip(host.sessionFDs, opened).filter { fd, was in Self.identity(of: fd) == was }.map(\.0)
        #expect(stillOpen.isEmpty)
    }

    /// The connections a session opened, in order.
    final class Connections {
        var all: [ChromiumHostConnection] = []
    }
}
#endif
