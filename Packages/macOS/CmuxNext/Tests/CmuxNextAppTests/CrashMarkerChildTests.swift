@testable import CmuxNextApp
import CmuxNextBrowser
import Darwin
import Foundation
import Testing

/// Crashes where the run marker's fatal-signal handler could not run left
/// no signal, so the next launch restored without the restart notice
/// (cx-30ko):
/// - a stack overflow: the handler had no alternate signal stack to run on,
///   first on any thread, then on any thread but the main one (cx-feao0);
/// - a crash after a failed Chromium start: Chromium resets every signal
///   action when it starts, and the handlers came back only when it started.
///
/// Each test crashes a child process (an exit test) with the app's run
/// marker live, then reads the folder it left the way the next launch does.
struct CrashMarkerChildTests {
    @Test func aStackOverflowShowsTheNoticeOnTheNextLaunch() async throws {
        let directory = CrashChild.directory("overflow", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .failure) {
            await CrashChild.overflowTheMainThread()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.signal == SIGSEGV || previous.signal == SIGBUS,
                "a stack overflow recorded no signal (\(previous.signal.map(String.init) ?? "none"))")
        #expect(LaunchRecovery.decide(previous: previous).isRestart, "a stack overflow showed no restart notice")
    }

    @Test func aStackOverflowOnABackgroundThreadShowsTheNoticeOnTheNextLaunch() async throws {
        let directory = CrashChild.directory("thread-overflow", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .failure) {
            await CrashChild.overflowABackgroundThread()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.signal == SIGSEGV || previous.signal == SIGBUS,
                "a background thread's stack overflow recorded no signal (\(previous.signal.map(String.init) ?? "none"))")
        #expect(LaunchRecovery.decide(previous: previous).isRestart,
                "a background thread's stack overflow showed no restart notice")
    }

    @Test func aCrashAfterAFailedChromiumStartShowsTheNoticeOnTheNextLaunch() async throws {
        let directory = CrashChild.directory("chromium", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .failure) {
            await CrashChild.crashAfterAFailedChromiumStart()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.signal == SIGSEGV || previous.signal == SIGBUS,
                "a crash after a failed Chromium start recorded no signal (\(previous.signal.map(String.init) ?? "none"))")
        #expect(LaunchRecovery.decide(previous: previous).isRestart,
                "a crash after a failed Chromium start showed no restart notice")
    }

    /// A restart that crashes again while a restored page loads holds that page on the next launch,
    /// and only that page (user, 2026-10-27: every other tab loads when it shows).
    @Test func aPageLoadingInAQuickSecondCrashIsHeldOnTheNextLaunch() async throws {
        let directory = CrashChild.directory("page", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The run before crashed: the child's run watches for a loop.
        let crashed = PreviousRun(pid: 1, launched: Date(timeIntervalSince1970: 1_790_000_000), recovery: false, survived: true, signal: nil, quitting: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(crashed).write(to: directory.appending(path: "run.json"))
        try "\(SIGSEGV)\n".write(to: directory.appending(path: "run.signal"), atomically: true, encoding: .utf8)
        await #expect(processExitsWith: .failure) {
            await CrashChild.crashWhileAPageLoads()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        let recovery = LaunchRecovery.decide(previous: previous)
        #expect(recovery.isSafeRestart)
        #expect(recovery.crashedPages == ["tab-crashing"], "held \(recovery.crashedPages.sorted())")
    }
}

/// A fault signal sent by software (`raise`, `pthread_kill`) reads like a
/// CPU fault on Darwin arm64: XNU gives SIGSEGV, SIGBUS and SIGILL fixed
/// fault codes and SIGTRAP code 0, never `SI_USER`. The handler returned
/// as for a fault, nothing ran the signal again, and the process went on
/// (cx-sjv65). A Swift trap (`brk`, also SIGTRAP code 0) must still end on
/// its own instruction. The syndrome check reads arm64 state only.
#if arch(arm64)
struct CrashMarkerSentSignalTests {
    @Test func aRaisedSegmentationFaultEndsTheProcess() async throws {
        let directory = CrashChild.directory("raise-segv", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .signal(SIGSEGV)) {
            await CrashChild.send(SIGSEGV, name: "raise-segv", toSelf: false)
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.signal == SIGSEGV, "a raised SIGSEGV recorded \(previous.signal.map(String.init) ?? "none")")
    }

    @Test func aTrapSentToTheThreadEndsTheProcess() async throws {
        let directory = CrashChild.directory("kill-trap", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .signal(SIGTRAP)) {
            await CrashChild.send(SIGTRAP, name: "kill-trap", toSelf: true)
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.signal == SIGTRAP, "a SIGTRAP from pthread_kill recorded \(previous.signal.map(String.init) ?? "none")")
    }

    @Test func aSwiftTrapStillEndsOnItsInstruction() async throws {
        let directory = CrashChild.directory("swift-trap", parent: getpid())
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(processExitsWith: .signal(SIGTRAP)) {
            await CrashChild.trap()
        }
        let previous = try #require(CrashChild.previous(in: directory), "the child left no run.json")
        #expect(previous.signal == SIGTRAP, "a Swift trap recorded \(previous.signal.map(String.init) ?? "none")")
    }

    /// The classifier on a built context: only a supervisor-call syndrome
    /// with `svc #0x80` before the pc reads as sent; a data abort, a `brk`,
    /// a supervisor call that restored some other pc (`sigreturn`) and an
    /// unreadable pc read as faults.
    @Test func onlyAReturningSystemCallReadsAsSent() throws {
        let code: [UInt32] = [0xD400_1001, 0xD503_201F, 0xD503_201F] // svc #0x80; nop; nop
        try code.withUnsafeBufferPointer { buffer in
            let start = try #require(buffer.baseAddress)
            let afterSvc = UInt64(UInt(bitPattern: start) + 4)
            #expect(Self.arrived(esr: 0x5600_0080, pc: afterSvc))
            #expect(!Self.arrived(esr: 0x9200_0046, pc: afterSvc), "a data abort read as sent")
            #expect(!Self.arrived(esr: 0xF200_0001, pc: afterSvc), "a brk read as sent")
            #expect(!Self.arrived(esr: 0x5600_0080, pc: afterSvc + 4), "a sigreturn to a fault pc read as sent")
            #expect(!Self.arrived(esr: 0x5600_0080, pc: 4), "an unreadable pc read as sent")
        }
        #expect(arrivedOnASystemCall(nil), "no context must re-raise")
    }

    private static func arrived(esr: UInt32, pc: UInt64) -> Bool {
        var machine = __darwin_mcontext64()
        machine.__es.__esr = esr
        machine.__ss.__pc = pc
        return withUnsafeMutablePointer(to: &machine) { state in
            var context = ucontext_t()
            context.uc_mcontext = state
            return withUnsafeMutablePointer(to: &context) { arrivedOnASystemCall(UnsafeMutableRawPointer($0)) }
        }
    }
}
#endif

/// What the exit-test children run. An exit test captures nothing, so the
/// child finds its marker folder from its parent's pid.
enum CrashChild {
    static func directory(_ name: String, parent: pid_t) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cmux-crash-marker-\(parent)-\(name)", directoryHint: .isDirectory)
    }

    static func previous(in directory: URL) -> PreviousRun? {
        AppRunMarker.readPrevious(marker: directory.appending(path: "run.json"), signal: directory.appending(path: "run.signal"),
                                  exception: directory.appending(path: "run.exception"))
    }

    /// The app's launch: the run marker on the main thread, `run.json` on
    /// disk.
    @MainActor
    static func markRun(_ name: String) async -> AppRunMarker {
        let marker = AppRunMarker(directory: directory(name, parent: getppid()))
        _ = await marker.flush()
        return marker
    }

    /// A restart (the parent wrote a crashed run) starts a restored page, then crashes.
    @MainActor
    static func crashWhileAPageLoads() async {
        let marker = await markRun("page")
        marker.notePageStarted("tab-crashing")
        _ = await marker.flush()
        raise(SIGSEGV)
        withExtendedLifetime(marker) {}
    }

    /// Runaway recursion on the main thread, where the app installs its
    /// handlers.
    @MainActor
    static func overflowTheMainThread() async {
        let marker = await markRun("overflow")
        _ = recurse(1)
        withExtendedLifetime(marker) {}
    }

    /// Runaway recursion on a thread started after launch (as Chromium's
    /// and the system's worker threads are), while the main thread waits.
    @MainActor
    static func overflowABackgroundThread() async {
        let marker = await markRun("thread-overflow")
        Thread { _ = recurse(1) }.start()
        // The overflow ends the process well before this; if it does not,
        // the child exits cleanly and the exit test fails.
        try? await Task.sleep(for: .seconds(30))
        withExtendedLifetime(marker) {}
    }

    /// Chromium fails to start (no runtime at this layout) after it reset
    /// the signal actions, as `CefInitialize` does before it can fail; then
    /// the app crashes on a bad memory access.
    @MainActor
    static func crashAfterAFailedChromiumStart() async {
        let marker = await markRun("chromium")
        let missing = FileManager.default.temporaryDirectory.appending(path: "cmux-no-cef-\(UUID().uuidString)")
        let engine = CEFEngine(layout: CEFRuntimeLayout(frameworksDirectory: missing, mainBundle: missing,
                                                        helperApp: missing.appending(path: "None Helper.app")),
                               stores: .inMemory(), signInCallbacks: CEFSignInCallbacks())
        AppRunMarker.keepSignalHandlers(marker, across: engine, reporter: nil)
        for signal in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGFPE, SIGSYS] { _ = Darwin.signal(signal, SIG_DFL) }
        await engine.warmStart(reason: "test")
        #expect(!engine.isRunning)
        badAccess()
        withExtendedLifetime(marker) {}
    }

    /// Sends `signal` with `raise`, or with `pthread_kill` to this thread,
    /// then returns: a lost signal lets the child exit normally.
    @MainActor
    static func send(_ signal: Int32, name: String, toSelf: Bool) async {
        let marker = await markRun(name)
        _ = toSelf ? pthread_kill(pthread_self(), signal) : raise(signal)
        withExtendedLifetime(marker) {}
    }

    /// A Swift runtime trap (`brk` on arm64).
    @MainActor
    static func trap() async {
        let marker = await markRun("swift-trap")
        let values: [Int] = []
        _ = values[Int(getpid() & 1) + 1]
        withExtendedLifetime(marker) {}
    }

    /// A store to an unmapped address: SIGSEGV (or SIGBUS) from the CPU.
    @inline(never)
    static func badAccess() {
        UnsafeMutablePointer<Int>(bitPattern: 16)?.pointee = 1
    }

    /// About 300 bytes of stack per call, never a tail call. Any thread.
    @inline(never)
    nonisolated static func recurse(_ depth: Int) -> Int {
        var frame: (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) =
            (depth, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        if depth == Int.max { return 0 }
        let below = withUnsafeMutableBytes(of: &frame) { bytes in recurse(depth &+ Int(bytes[0] & 1) &+ 1) }
        return below &+ frame.0
    }
}
