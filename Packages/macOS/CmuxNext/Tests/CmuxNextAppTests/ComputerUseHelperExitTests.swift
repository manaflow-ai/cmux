import CmuxNextAgentActivity
@testable import CmuxNextApp
import CmuxNextCompat
@testable import CmuxNextComputerUse
import CmuxNextSettings
import CmuxNextWakeupsTestSupport
import Darwin
import Foundation
import Testing

/// The helper can exit without this app asking: macOS offers "Quit & Reopen"
/// after the person adds it in Screen & System Audio Recording, and only
/// quits it. The app kept `.running(pid)`, so `computer_use.status` said
/// "ready", the setup window waited for the grant forever, and every
/// computer use call failed until the app restarted (seen 2026-10-27, macOS 26.6).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComputerUseHelperExitTests {
    private func makeDaemon(_ launcher: ExitingHelperLauncher,
                            clock: any Clock<Duration> = ContinuousClock()) -> (ComputerUseHelperDaemon, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cua-exit-\(UUID().uuidString.prefix(8))")
        let daemon = ComputerUseHelperDaemon(identity: CuaHelperIdentity(isSigned: { _ in true }),
                                             candidates: { [root.appending(path: "missing/cmux Computer Use.app")] },
                                             launcher: launcher, staging: .passing(root: root),
                                             socketPath: root.appending(path: "s/cua.sock").path,
                                             stateDirectory: root.appending(path: "state"), clock: clock)
        return (daemon, root)
    }

    @Test func anExitTheAppDidNotCauseStartsTheHelperAgain() async throws {
        let launcher = ExitingHelperLauncher()
        let (daemon, root) = makeDaemon(launcher)
        defer { try? FileManager.default.removeItem(at: root) }
        await daemon.apply(enabled: true)
        try #require(daemon.state == .running(601))

        launcher.exit(601)
        try #require(daemon.state != .running(601), "the app must notice that its helper exited")
        #expect(daemon.configuration == nil, "no reader gets the exited helper's tokens")

        await launcher.waitForLaunches(2)
        await daemon.apply(enabled: true)
        #expect(daemon.state == .running(602))
        #expect(launcher.terminated.isEmpty, "the exited helper needs no stop")
    }

    /// The user's case (2026-10-27, nightly cc0d757): System Settings quit the
    /// helper after a grant, the app still said `.running`, and Stop / Focus
    /// Computer Use answered "The Computer Use helper did not answer." until
    /// cmux restarted. When the exit is missed, the first request that finds
    /// no listener notices that the process is gone, starts the helper again
    /// and says so.
    @Test func aRequestToAHelperThatIsGoneStartsItAgain() async throws {
        let launcher = ExitingHelperLauncher()
        let (daemon, root) = makeDaemon(launcher)
        defer { try? FileManager.default.removeItem(at: root) }
        await daemon.apply(enabled: true)
        try #require(daemon.state == .running(601))

        // No listener answers at the socket, and no exit event comes.
        launcher.vanish(601)
        let sessions = CuaComputerUseSessions(configuration: { daemon.configuration }, phase: { .ready },
                                              confirmRunning: { daemon.confirmRunning() })
        await #expect(throws: ComputerUseSessionError.notRunning(ComputerUseSessionStrings.helperRestarting)) {
            try await sessions.liveSessions()
        }
        #expect(daemon.state != .running(601), "the app must notice that its helper is gone")
        #expect(daemon.configuration == nil, "no reader gets the gone helper's tokens")
        #expect(launcher.cancelled == [601], "the missed exit's watch ends")

        await launcher.waitForLaunches(2)
        await daemon.apply(enabled: true)
        #expect(daemon.state == .running(602))
        #expect(launcher.terminated.isEmpty, "the gone helper needs no stop")

        // A live helper that does not answer keeps the old reason, and nothing restarts.
        await #expect(throws: ComputerUseSessionError.failed(ComputerUseSessionStrings.hostUnreachable)) {
            try await sessions.liveSessions()
        }
        #expect(daemon.state == .running(602))
        #expect(launcher.launched == [601, 602])
    }

    @Test func anExitLoopStopsTheRestartsUntilTheHelperIsRestarted() async throws {
        let launcher = ExitingHelperLauncher()
        let (daemon, root) = makeDaemon(launcher)
        defer { try? FileManager.default.removeItem(at: root) }
        await daemon.apply(enabled: true)
        for restart in 1...3 {
            let pid = pid_t(600 + restart)
            try #require(daemon.state == .running(pid))
            launcher.exit(pid)
            try #require(daemon.state != .running(pid), "exit \(restart) is noticed")
            await launcher.waitForLaunches(restart + 1)
            await daemon.apply(enabled: true)
        }
        try #require(daemon.state == .running(604))

        launcher.exit(604)
        #expect(daemon.state == .failed, "a fourth exit within a minute stops the restarts")
        #expect(daemon.configuration == nil)
        #expect(launcher.launched.count == 4)

        // Restart Helper (the setup's failed state) starts it again with a fresh budget.
        await daemon.restartLegacy()
        #expect(daemon.state == .running(605))
        launcher.exit(605)
        await launcher.waitForLaunches(6)
        await daemon.apply(enabled: true)
        #expect(daemon.state == .running(606))
    }

    @Test func aStopRestartOrQuitThisAppMadeStartsNoExtraHelper() async throws {
        let launcher = ExitingHelperLauncher()
        let (daemon, root) = makeDaemon(launcher)
        defer { try? FileManager.default.removeItem(at: root) }
        await daemon.apply(enabled: true)
        await daemon.restartLegacy()
        // The exit event of the helper the restart stopped can already be queued.
        launcher.exit(601)
        #expect(daemon.state == .running(602))

        await daemon.apply(enabled: false)
        launcher.exit(602)
        #expect(daemon.state == .off)

        await daemon.apply(enabled: true)
        daemon.applicationWillTerminate()
        launcher.exit(603)
        #expect(daemon.state == .off)

        #expect(launcher.launched == [601, 602, 603])
        #expect(launcher.terminated == [601, 602, 603])
        #expect(launcher.cancelled == [601, 602, 603], "each stop ends its exit watch")
    }

    @Test func restartsOlderThanAMinuteNoLongerCount() async throws {
        let launcher = ExitingHelperLauncher()
        let clock = ManualClock()
        let (daemon, root) = makeDaemon(launcher, clock: clock)
        defer { try? FileManager.default.removeItem(at: root) }
        await daemon.apply(enabled: true)
        for restart in 1...6 {
            let pid = pid_t(600 + restart)
            try #require(daemon.state == .running(pid))
            // One exit every 30 seconds: at most two restarts fall within a minute.
            clock.advance(by: .seconds(30))
            launcher.exit(pid)
            await launcher.waitForLaunches(restart + 1)
            await daemon.apply(enabled: true)
        }
        #expect(daemon.state == .running(607))
    }

    /// The launchers' kernel watch, on a real child: an exit while watched,
    /// then a pid that exited before its watch armed.
    @Test func theKernelWatchReportsAnExit() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/cat")
        let input = Pipe()
        child.standardInput = input
        let reaped = AsyncStream<Void>.makeStream()
        child.terminationHandler = { _ in reaped.continuation.finish() }
        try child.run()
        var cancel: (@MainActor () -> Void)?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancel = ComputerUseHelperExitWatch.watch(child.processIdentifier) { continuation.resume() }
            // cat exits at the end of its input.
            try? input.fileHandleForWriting.close()
        }
        cancel?()
        for await _ in reaped.stream {}
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cancel = ComputerUseHelperExitWatch.watch(child.processIdentifier) { continuation.resume() }
        }
        cancel?()
    }

    // MARK: Helper v2

    /// NIGHTLY builds carry no helper v2. With driver "upstream" nothing started: the
    /// legacy helper was stopped, the helper v2 was "unavailable", every agent's computer use
    /// found no socket, and setup said "starting" forever (2026-10-29). The legacy helper runs
    /// in its place, agents get its socket, and the stored setting is not touched.
    @Test func upstreamWithoutTheHelperV2InThisBuildRunsTheLegacyHelper() async throws {
        let launcher = ExitingHelperLauncher()
        let spawner = ExitingV2Spawner()
        let root = FileManager.default.temporaryDirectory.appending(path: "cua-fallback-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = ComputerUseHelperV2(directory: root.appending(path: "v2").path, helperApp: { nil },
                                           staging: .passing(root: root), spawner: spawner, clock: ManualClock(), exitGrace: .zero)
        let daemon = ComputerUseHelperDaemon(identity: CuaHelperIdentity(isSigned: { _ in true }),
                                             candidates: { [root.appending(path: "missing/cmux Computer Use.app")] },
                                             launcher: launcher, staging: .passing(root: root),
                                             socketPath: root.appending(path: "s/cua.sock").path,
                                             stateDirectory: root.appending(path: "state"), upstream: upstream)
        try #require(!upstream.isInBuild)
        var settings = ComputerUseSettings()
        settings.enabled = true
        settings.driver = .upstream

        let route = ComputerUseHelperDaemon.route(settings, disabledByPolicy: false, upstreamInBuild: false)
        #expect(route.legacy && !route.upstream)
        let inBuild = ComputerUseHelperDaemon.route(settings, disabledByPolicy: false, upstreamInBuild: true)
        #expect(!inBuild.legacy && inBuild.upstream, "a build with the helper v2 still runs it")
        #expect(daemon.effectiveDriver(.upstream) == .legacy)
        #expect(daemon.effectiveDriver(.legacy) == .legacy)

        await daemon.apply(settings, disabledByPolicy: false)
        #expect(daemon.state == .running(601), "the legacy helper runs in place of the missing helper v2")
        #expect(spawner.spawned.isEmpty, "the missing helper v2 never starts")
        #expect(!daemon.childEnvironment.isEmpty, "agents get the legacy helper's socket and token")

        settings.enabled = false
        await daemon.apply(settings, disabledByPolicy: false)
        #expect(daemon.state == .off)
        #expect(launcher.terminated == [601])
    }

    private func makeV2(_ spawner: ExitingV2Spawner) -> (ComputerUseHelperV2, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "cua-v2-exit-\(UUID().uuidString.prefix(8))")
        let helper = ComputerUseHelperV2(directory: root.appending(path: "scope").path,
                                         helperApp: { URL(fileURLWithPath: "/missing/cmux Computer Use (dev).app") },
                                         staging: .passing(root: root), spawner: spawner, clock: ManualClock(), exitGrace: .zero)
        spawner.socketPath = helper.socketPath
        return (helper, root)
    }

    @Test func anExitTheAppDidNotCauseStartsTheHelperV2Again() async throws {
        let spawner = ExitingV2Spawner()
        let (helper, root) = makeV2(spawner)
        defer { try? FileManager.default.removeItem(at: root) }
        await helper.apply(enabled: true)
        try #require(helper.state == .running(701))

        spawner.exit(701)
        try #require(helper.state != .running(701), "the app must notice that its helper v2 exited")
        #expect(!FileManager.default.fileExists(atPath: helper.endpointPath), "acpmux must not find the exited helper")
        #expect(spawner.terminated == [701], "the exited child is reaped")

        await spawner.waitForWatches(2)
        #expect(helper.state == .running(702))
        await helper.stop()
    }

    @Test func aStopThisAppMadeStartsNoExtraHelperV2() async throws {
        let spawner = ExitingV2Spawner()
        let (helper, root) = makeV2(spawner)
        defer { try? FileManager.default.removeItem(at: root) }
        await helper.apply(enabled: true)
        await helper.apply(enabled: false)
        spawner.exit(701)
        #expect(helper.state == .off)
        await helper.apply(enabled: true)
        helper.terminateForQuit()
        spawner.exit(702)
        #expect(helper.state == .off)
        #expect(spawner.spawned == [701, 702])
        #expect(spawner.cancelled == [701, 702], "each stop ends its exit watch")
    }
}

/// Launches pretend helpers and lets a test end one by itself.
@MainActor
private final class ExitingHelperLauncher: ComputerUseHelperLaunching {
    private(set) var launched: [pid_t] = []
    private(set) var terminated: [pid_t] = []
    /// The pids whose exit watch the daemon cancelled.
    private(set) var cancelled: [pid_t] = []
    private var exitHandlers: [pid_t: @MainActor () -> Void] = [:]
    private var launchWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    func launch(_ app: URL, arguments: [String], environment: [String: String]) async -> pid_t? {
        let pid = pid_t(601 + launched.count)
        launched.append(pid)
        if let waiter = launchWaiter, launched.count >= waiter.count {
            launchWaiter = nil
            waiter.continuation.resume()
        }
        return pid
    }

    func terminate(_ pid: pid_t) { terminated.append(pid) }

    /// Helpers that are gone without an exit event (``vanish(_:)``).
    private var gone: Set<pid_t> = []

    func isRunning(_ pid: pid_t) -> Bool { !gone.contains(pid) }

    func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        exitHandlers[pid] = onExit
        return { [weak self] in self?.cancelled.append(pid) }
    }

    /// The helper `pid` is gone, and its exit event never comes.
    func vanish(_ pid: pid_t) { gone.insert(pid) }

    /// The helper `pid` exits. The handler runs even after a cancel: the
    /// kernel event can already be queued when the daemon cancels its watch.
    func exit(_ pid: pid_t) { exitHandlers[pid]?() }

    func waitForLaunches(_ count: Int) async {
        if launched.count >= count { return }
        await withCheckedContinuation { launchWaiter = (count, $0) }
    }
}

/// Spawns pretend helper v2 children that answer `ready` at once.
@MainActor
private final class ExitingV2Spawner: ComputerUseHelperV2Spawning {
    private nonisolated let store = Mutex<(spawned: [pid_t], terminated: [pid_t], socketPath: String)>(([], [], ""))
    private(set) var cancelled: [pid_t] = []
    private var exitHandlers: [pid_t: @MainActor () -> Void] = [:]
    private var watches = 0
    private var watchWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

    nonisolated var spawned: [pid_t] { store.withLock { $0.spawned } }
    nonisolated var terminated: [pid_t] { store.withLock { $0.terminated } }
    nonisolated var socketPath: String {
        get { store.withLock { $0.socketPath } }
        set { store.withLock { $0.socketPath = newValue } }
    }

    nonisolated func spawn(executable: URL, environment: [String: String], logPath: String) throws -> ComputerUseHelperV2Child {
        let (pid, socket) = store.withLock { state in
            state.spawned.append(pid_t(701 + state.spawned.count))
            return (state.spawned[state.spawned.count - 1], state.socketPath)
        }
        let (lines, continuation) = AsyncStream<Data>.makeStream()
        continuation.yield(ComputerUseHelperV2.line(["type": "ready", "socket": socket]).dropLast())
        return ComputerUseHelperV2Child(pid: pid, input: -1, lines: lines)
    }

    nonisolated func terminate(_ pid: pid_t) {
        store.withLock { $0.terminated.append(pid) }
    }

    func watchExit(of pid: pid_t, onExit: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        exitHandlers[pid] = onExit
        watches += 1
        if let waiter = watchWaiter, watches >= waiter.count {
            watchWaiter = nil
            waiter.continuation.resume()
        }
        return { [weak self] in self?.cancelled.append(pid) }
    }

    func exit(_ pid: pid_t) { exitHandlers[pid]?() }

    /// Returns once `count` helpers ran (the watch starts as the helper is ready).
    func waitForWatches(_ count: Int) async {
        if watches >= count { return }
        await withCheckedContinuation { watchWaiter = (count, $0) }
    }
}
