#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextWakeups
import Darwin
import Foundation
import Testing

/// The Chromium host's idle exit (`chromiumHostIdleExit`, p07-memory-050) without Chromium: the
/// stand-in launcher of ``ChromiumHostSessionTests`` plays the host, the idle deadline is a
/// ``MainDeadline`` on a wake-up queue only the test fires, and a borderless window decides whether
/// the page is live. A host whose page is in
/// no window for the idle deadline quits; the page's next show starts a new host under its
/// stand-in; a host that ignores the quit is killed at the quit limit, so none is left behind.
@MainActor
@Suite struct ChromiumHostIdleExitTests {
    typealias Fake = ChromiumHostSessionTests
    private let helpers = ChromiumHostSessionTests()
    private static let idle: Duration = .seconds(300)

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func picture() -> CGImage? {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context?.makeImage()
    }

    /// A session shown in `window`, its first host running page a.
    private func running(in window: NSWindow, launcher: Fake.FakeLauncher, rig: IdleDeadlineRig,
                         idleExit: Duration? = idle, quitLimit: Duration = .seconds(15)) async throws -> (ChromiumHostSession, Fake.FakeHost) {
        let session = ChromiumHostSession(configuration: Fake.configuration, launcher: launcher,
                                          quitLimit: quitLimit,
                                          idleExit: idleExit.map { ChromiumHostIdleExit(after: $0, deadlines: rig.deadlines) },
                                          standInPicture: { Self.picture() })
        window.contentView?.addSubview(session.view)
        session.open("https://a.example/")
        let host = try await helpers.nextLaunch(launcher)
        helpers.answer(host, context: 5, address: "https://a.example/")
        try await helpers.until("running with context 5") { session.phase == .running && session.contextID == 5 }
        return (session, host)
    }

    @Test(.timeLimit(.minutes(1))) func aHostWithNoLivePageQuitsAtTheDeadlineAndTheNextShowRestartsIt() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig)
        #expect(!session.isIdleExitArmed)

        session.view.removeFromSuperview()
        #expect(session.isIdleExitArmed)
        rig.fire(after: Self.idle)
        _ = try #require(await helpers.frame(.quit, in: first.wire.frames))
        // The page's last picture covers it while no host shows it.
        #expect(session.view.standIn != nil)
        launcher.end(first, ChromiumHostExit(signal: nil, status: 0))
        try await helpers.until("exited idle") { session.phase == .exitedIdle }
        #expect(session.idleExits == 1)
        #expect(session.restarts == 0)
        #expect(launcher.count == 1)
        #expect(launcher.killed.isEmpty)

        // The next show starts a new host with the page's URL, under the stand-in until its context.
        window.contentView?.addSubview(session.view)
        let second = try await helpers.nextLaunch(launcher)
        let opened = try await helpers.firstFrame(of: second)
        #expect(opened.kind == .navigate)
        #expect(opened.text == "https://a.example/")
        #expect(session.phase == .starting)
        #expect(session.view.standIn != nil)
        helpers.answer(second, context: 9, address: "https://a.example/")
        try await helpers.until("running with context 9") { session.phase == .running && session.contextID == 9 }
        #expect(session.view.standIn == nil)
        #expect(session.restarts == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aPageShownBeforeTheDeadlineKeepsItsHost() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig)
        session.view.removeFromSuperview()
        rig.advance(by: Self.idle - .seconds(1))
        window.contentView?.addSubview(session.view)
        #expect(!session.isIdleExitArmed)
        rig.fire(after: Self.idle)
        #expect(session.phase == .running)
        #expect(session.pid == first.pid)
        #expect(session.idleExits == 0)
        #expect(launcher.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func noDeadlineKeepsTheHost() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig, idleExit: nil)
        session.view.removeFromSuperview()
        #expect(!session.isIdleExitArmed)
        rig.fire(after: Self.idle)
        #expect(session.phase == .running)
        #expect(session.pid == first.pid)
    }

    /// A host whose UI thread hangs never acts on the idle quit: the quit limit kills it, so no
    /// host outlives its idle deadline by more than that limit.
    @Test(.timeLimit(.minutes(1))) func aHostThatIgnoresTheIdleQuitIsKilledAtTheQuitLimit() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig, quitLimit: .milliseconds(20))
        session.view.removeFromSuperview()
        rig.fire(after: Self.idle)
        _ = try #require(await helpers.frame(.quit, in: first.wire.frames))
        // The host's UI thread hangs: it never acts on quit and never exits by itself.
        try await helpers.until("exited idle after the SIGKILL") { session.phase == .exitedIdle }
        #expect(launcher.killed == [first.pid])
        #expect(session.exits == ["signal \(SIGKILL)"])
        #expect(launcher.count == 1)
    }

    /// Shown again while the idle quit is in flight: the next host starts once the quitting one ended.
    @Test(.timeLimit(.minutes(1))) func aShowWhileTheHostQuitsStartsTheNextHostAfterItEnds() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig)
        session.view.removeFromSuperview()
        rig.fire(after: Self.idle)
        _ = try #require(await helpers.frame(.quit, in: first.wire.frames))
        window.contentView?.addSubview(session.view)
        #expect(launcher.count == 1)
        launcher.end(first, ChromiumHostExit(signal: nil, status: 0))
        let second = try await helpers.nextLaunch(launcher)
        let opened = try await helpers.firstFrame(of: second)
        #expect(opened.text == "https://a.example/")
        #expect(session.idleExits == 1)
        #expect(session.restarts == 0)
        #expect(session.phase == .starting)
    }

    /// A close after the idle exit ends the session: no stand-in, and a later show starts nothing.
    @Test(.timeLimit(.minutes(1))) func aCloseAfterTheIdleExitStartsNoHostOnTheNextShow() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig)
        session.view.removeFromSuperview()
        rig.fire(after: Self.idle)
        _ = try #require(await helpers.frame(.quit, in: first.wire.frames))
        launcher.end(first, ChromiumHostExit(signal: nil, status: 0))
        try await helpers.until("exited idle") { session.phase == .exitedIdle }
        session.close()
        #expect(session.phase == .idle)
        #expect(session.view.standIn == nil)
        window.contentView?.addSubview(session.view)
        #expect(session.phase == .idle)
        #expect(launcher.count == 1)
    }

    /// Shown and hidden again while the idle quit is in flight: the page is hidden when the host
    /// ends, so no host starts until the page shows.
    @Test(.timeLimit(.minutes(1))) func aShowThenHideWhileTheHostQuitsStartsNoHost() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig)
        session.view.removeFromSuperview()
        rig.fire(after: Self.idle)
        _ = try #require(await helpers.frame(.quit, in: first.wire.frames))
        window.contentView?.addSubview(session.view)
        session.view.removeFromSuperview()
        launcher.end(first, ChromiumHostExit(signal: nil, status: 0))
        try await helpers.until("exited idle") { session.phase == .exitedIdle }
        #expect(launcher.count == 1)
        #expect(session.idleExits == 1)

        window.contentView?.addSubview(session.view)
        let second = try await helpers.nextLaunch(launcher)
        #expect(try await helpers.firstFrame(of: second).text == "https://a.example/")
        #expect(session.phase == .starting)
    }

    /// A hidden page's host that crashes waits for the page's next show, as Chrome reloads a
    /// crashed background tab only when it is activated.
    @Test(.timeLimit(.minutes(1))) func aHiddenPagesCrashedHostStartsOnlyOnTheNextShow() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let (session, first) = try await running(in: window, launcher: launcher, rig: rig)
        session.view.removeFromSuperview()
        launcher.end(first, ChromiumHostExit(signal: SIGSEGV, status: nil))
        try await helpers.until("exited while hidden") { session.phase == .exitedIdle }
        #expect(launcher.count == 1)
        #expect(session.restarts == 0)
        #expect(session.idleExits == 0)
        #expect(!session.isIdleExitArmed)

        window.contentView?.addSubview(session.view)
        let second = try await helpers.nextLaunch(launcher)
        #expect(try await helpers.firstFrame(of: second).text == "https://a.example/")
        #expect(session.restarts == 0)
    }

    @Test func theReportKeepsAFractionalIdleDeadline() {
        let rig = IdleDeadlineRig()
        let session = ChromiumHostSession(configuration: Fake.configuration, launcher: Fake.FakeLauncher(),
                                          idleExit: ChromiumHostIdleExit(after: .milliseconds(1500), deadlines: rig.deadlines))
        #expect(session.report["idle_exit_s"] as? Double == 1.5)
    }

    // MARK: The prototype

    /// The prototype with an idle deadline and its switch (`cefHelperHost`) on, its sessions on `launcher`.
    private func prototype(launcher: Fake.FakeLauncher, rig: IdleDeadlineRig) -> ChromiumHostPrototype {
        ChromiumHostPrototype(makeConfiguration: { Fake.configuration }, isOn: { true },
                              mainWork: MainWorkScheduler(budget: MainFrameBudget()), deadlines: rig.deadlines,
                              idleExitAfter: Self.idle) { configuration, idleExit in
            ChromiumHostSession(configuration: configuration, launcher: launcher, idleExit: idleExit)
        }
    }

    /// With an idle deadline, a closed pane still ends its host at once; only a detached page waits.
    @Test(.timeLimit(.minutes(1))) func aClosedPaneEndsItsHostAtOnceWithAnIdleDeadline() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(pane)
        let prototype = prototype(launcher: launcher, rig: rig)
        #expect(prototype.open("https://a.example/", over: pane, focus: false)["error"] == nil)
        let host = try await helpers.nextLaunch(launcher)
        helpers.answer(host, context: 5, address: "https://a.example/")
        try await helpers.until("running") { prototype.report["phase"] as? String == "running" }

        pane.removeFromSuperview()
        _ = try #require(await helpers.frame(.quit, in: host.wire.frames))
        #expect(prototype.report["idle_exit_armed"] as? Bool == false)
        launcher.end(host, ChromiumHostExit(signal: nil, status: 0))
        try await helpers.until("closed") { prototype.report["phase"] as? String == "idle" }
        #expect(launcher.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aDetachedPageKeepsItsHostUntilTheIdleDeadline() async throws {
        let launcher = Fake.FakeLauncher()
        let rig = IdleDeadlineRig()
        let window = window()
        let pane = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(pane)
        let prototype = prototype(launcher: launcher, rig: rig)
        _ = prototype.open("https://a.example/", over: pane, focus: false)
        let host = try await helpers.nextLaunch(launcher)
        helpers.answer(host, context: 5, address: "https://a.example/")
        try await helpers.until("running") { prototype.report["phase"] as? String == "running" }

        let report = prototype.detach()
        #expect(report["phase"] as? String == "running")
        #expect(report["idle_exit_armed"] as? Bool == true)
        #expect(report["live"] as? Bool == false)
        rig.fire(after: Self.idle)
        _ = try #require(await helpers.frame(.quit, in: host.wire.frames))
    }

    @Test(arguments: [0, -1, 0.5, 3601, 1e21, Double.infinity, Double.nan] as [Double])
    func anIdleDeadlineOutOfRangeIsRefused(seconds: Double) {
        let rig = IdleDeadlineRig()
        let window = window()
        let prototype = prototype(launcher: Fake.FakeLauncher(), rig: rig)
        let reply = prototype.handle(op: "open", url: "https://a.example/", over: window.contentView, focus: false,
                                     idleExitSeconds: seconds)
        #expect((reply["error"] as? String)?.hasPrefix("idle_exit_s must be within") == true)
        #expect(prototype.report["phase"] as? String == "none")
    }
}

/// The app's deadline scheduler on a wake-up queue at a fake uptime that only the test moves and
/// fires, with posted work run in hand-fired frames (CmuxNextAppTests' MainDeadlineRig).
@MainActor
final class IdleDeadlineRig {
    let deadlines: MainDeadlineScheduler
    private let uptime = IdleRigUptime()
    private let budgetClock = IdleRigUptime(start: 1_000_000_000)
    private let queue: MainWakeUpQueue
    private let work: MainWorkScheduler
    private let keeper: FrameClient
    private var frames: Double = 0

    init() {
        let uptime = uptime, budgetClock = budgetClock
        queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in
            IdleRigWakeUpTimer()
        }
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: { budgetClock.now }), ledger: WakeupLedger()) { _ in
            IdleRigFrameLink()
        }
        deadlines = MainDeadlineScheduler(work: work, queue: queue)
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
    }

    /// Moves the uptime on without firing anything.
    func advance(by duration: Duration) { uptime.now += duration.nanosecondCount }

    /// Moves the uptime on by `duration`, fires the queue and runs the actions it posted in one frame.
    func fire(after duration: Duration) {
        advance(by: duration)
        queue.fire()
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }
}

/// A timer the queue arms and parks; the rig fires the queue itself.
private nonisolated final class IdleRigWakeUpTimer: MainWakeUpTimer {
    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {}
    func park() {}
}

private final class IdleRigFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

/// The rig's uptime in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class IdleRigUptime: Sendable {
    private let value: Atomic<UInt64>

    init(start: UInt64 = 0) {
        value = Atomic(start)
    }

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
#endif
