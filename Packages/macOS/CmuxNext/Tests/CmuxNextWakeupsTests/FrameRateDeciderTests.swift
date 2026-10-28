import AppKit
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// Frame rate classes: a display's link runs at the highest ``FrameRate`` its
/// armed clients ask for, as Chrome's viz picks the display interval from its frame sinks'
/// preferred intervals (components/viz/service/display/frame_rate_decider.cc).
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameRateDeciderTests {
    /// Only an ambient client armed: the link runs at 30 Hz. A motion client joining brings it to
    /// 120 at once; the motion client leaving takes it back to 30 after ``DisplayClock/framesBeforeLowering``
    /// frames.
    @Test func ambientAloneIs30AndMotionMakesIt120() throws {
        let links = RateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock(), followsClientRates: true)
        // Schedulers hold their windows weakly.
        let windows = [NSWindow.rateFixture(), NSWindow.rateFixture()]
        let windowA = FrameScheduler(name: "a", host: .window(windows[0]), displays: displays, budget: nil)
        let windowB = FrameScheduler(name: "b", host: .window(windows[1]), displays: displays, budget: nil)
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: windowA) { _ in true }
        let spring = FrameClient(owner: "spring", on: windowB) { _ in true }

        spinner.activate()
        let link = try #require(links.made.first)
        #expect(displays.frameRate(on: 1) == .ambient)
        let ambient = try #require(link.requested.last)
        #expect(ambient.minimum == 30 && ambient.maximum == 30 && ambient.preferred == 30)

        spring.activate()
        #expect(displays.linksMade == 1, "one link for the display, whatever the rate")
        #expect(displays.frameRate(on: 1) == .motion)
        let motion = try #require(link.requested.last)
        #expect(motion.minimum == 80 && motion.maximum == 120 && motion.preferred == 120)

        spring.deactivate()
        #expect(displays.frameRate(on: 1) == .motion, "lowering waits for frames")
        displays.fire(1, frames: DisplayClock.framesBeforeLowering - 1)
        #expect(displays.frameRate(on: 1) == .motion)
        displays.fire(1, frames: 1, from: 1)
        #expect(displays.frameRate(on: 1) == .ambient)
        #expect(link.requested.last?.maximum == 30)
        spinner.deactivate()
        #expect(displays.liveLinks == 0)
        #expect(displays.frameRate(on: 1) == nil)
        withExtendedLifetime(windows) {}
    }

    /// One scheduler with an ambient and a motion client asks for motion; the motion client going
    /// idle on its tick drops the rate to ambient once that held ``DisplayClock/framesBeforeLowering`` frames.
    @Test func oneSchedulerAsksForItsHighestClient() throws {
        let links = RateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock(), followsClientRates: true)
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let breath = FrameClient(owner: "breath", rate: .ambient, on: scheduler) { _ in true }
        var springFrames = 2
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in
            springFrames -= 1
            return springFrames > 0
        }
        breath.activate()
        spring.activate()
        #expect(scheduler.frameRate == .motion)
        #expect(displays.frameRate(on: 1) == .motion)

        displays.displayDidFire(1, timestamp: 1, refreshInterval: 1.0 / 120)
        #expect(displays.frameRate(on: 1) == .motion, "the spring still runs")
        displays.displayDidFire(1, timestamp: 1 + 1.0 / 120, refreshInterval: 1.0 / 120)
        #expect(scheduler.frameRate == .ambient)
        #expect(displays.frameRate(on: 1) == .motion, "the frame the spring settled on is the first below")
        displays.fire(1, frames: DisplayClock.framesBeforeLowering - 2, from: 2)
        #expect(displays.frameRate(on: 1) == .motion)
        displays.fire(1, frames: 1, from: 3)
        #expect(displays.frameRate(on: 1) == .ambient, "the spring settled: only the loop is left")
        #expect(try #require(links.made.first).requested.last?.maximum == 30)
        breath.deactivate()
    }

    /// The feature off: every link asks for the motion range, whatever its clients say.
    @Test func offRunsEveryLinkAtTheMotionRange() throws {
        let links = RateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in true }
        spinner.activate()
        #expect(displays.frameRate(on: 1) == .motion)
        let link = try #require(links.made.first)
        #expect(link.requested.map(\.maximum) == [120], "one request, the motion range")

        displays.followsClientRates = true
        #expect(displays.frameRate(on: 1) == .ambient, "turning it on asks the live link again, at once")
        displays.followsClientRates = false
        #expect(displays.frameRate(on: 1) == .motion)
        #expect(link.requested.map(\.maximum) == [120, 30, 120])
        spinner.deactivate()
    }

    /// A window nobody can see does not raise the rate: it ticks on the stall deadline, not the link.
    @Test func aHiddenWindowsMotionDoesNotCount() {
        let hidden = NSWindow.rateFixture(), shown = NSWindow.rateFixture()
        var hiddenVisible = false
        let displays = DisplayClock(makeLink: RateLinks().make, displayOf: { _ in 1 }, isVisible: { $0 !== hidden || hiddenVisible },
                                    clock: ManualClock(), followsClientRates: true)
        let back = FrameScheduler(name: "hidden", host: .window(hidden), displays: displays, budget: nil)
        let front = FrameScheduler(name: "shown", host: .window(shown), displays: displays, budget: nil)
        let spring = FrameClient(owner: "spring", on: back) { _ in true }
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: front) { _ in true }
        spring.activate()
        spinner.activate()
        displays.fire(1, frames: DisplayClock.framesBeforeLowering)
        #expect(displays.frameRate(on: 1) == .ambient)

        hiddenVisible = true
        displays.displayDidFire(1, timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(displays.frameRate(on: 1) == .motion, "the window can be seen again: its spring counts")
        spring.deactivate()
        spinner.deactivate()
    }

    /// A spring that starts again within ``DisplayClock/framesBeforeLowering`` frames of the last one
    /// finds the link still at 120: the link is never asked for 30 between the two (Chrome's
    /// `FrameRateDecider` waits `kMinNumOfFramesToToggleInterval` frames before it lowers).
    @Test func aSpringSoonAfterTheLastNeverSeesTheLinkLowered() throws {
        let links = RateLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock(), followsClientRates: true)
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in true }
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in true }
        spinner.activate()
        spring.activate()
        let link = try #require(links.made.first)
        let asked = link.requested.count
        for round in 0..<3 {
            spring.deactivate()
            displays.fire(1, frames: DisplayClock.framesBeforeLowering - 1, from: Double(round))
            spring.activate()
            displays.fire(1, frames: 2, from: Double(round) + 0.9)
        }
        #expect(link.requested.count == asked, "no 30 Hz request between the springs")
        #expect(displays.frameRate(on: 1) == .motion)
        spring.deactivate()
        spinner.deactivate()
    }

    /// A client of a faster rate arming while the link runs at 30 Hz (a key press beside a spinner)
    /// ticks on the next turn, not on the slow link's next callback up to 33 ms away; a link frame
    /// that comes first makes that tick unneeded.
    @Test func aFasterClientTicksOnTheNextTurn() async {
        let displays = DisplayClock(makeLink: RateLinks().make, displayOf: { _ in 1 }, clock: ManualClock(), mediaTime: { 0.5 },
                                    followsClientRates: true)
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: scheduler) { _ in true }
        spinner.activate()
        #expect(displays.frameRate(on: 1) == .ambient)
        var inputTicks = 0
        let input = FrameClient(inputStageOf: scheduler, owner: "input") { _ in inputTicks += 1; return true }
        input.activate()
        #expect(displays.frameRate(on: 1) == .motion, "a higher rate applies at once")
        for _ in 0..<100 where inputTicks == 0 { await Task.yield() }
        #expect(inputTicks == 1, "the first input frame does not wait for the 30 Hz link")

        input.deactivate()
        displays.fire(1, frames: DisplayClock.framesBeforeLowering, from: 1)
        #expect(displays.frameRate(on: 1) == .ambient)
        inputTicks = 0
        input.activate()
        displays.displayDidFire(1, timestamp: 2, refreshInterval: 1.0 / 120)
        for _ in 0..<100 { await Task.yield() }
        #expect(inputTicks == 1, "the link fired first: no extra tick")
        input.deactivate()
        spinner.deactivate()
    }

    /// A slow client never runs the link below two frames per stall deadline: a running 5 Hz link
    /// would miss the 100 ms deadline every frame, tick its subscribers on stalls and be rebuilt.
    @Test func aSlowClientKeepsTheLinkAboveTheStallDeadline() throws {
        let links = RateLinks()
        var now: CFTimeInterval = 0
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock(), mediaTime: { now },
                                    followsClientRates: true)
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let dots = FrameClient(owner: "dots", rate: .slow(5), on: scheduler) { _ in true }
        dots.activate()
        #expect(displays.frameRate(on: 1) == .slow(5))
        let link = try #require(links.made.first)
        let asked = try #require(link.requested.last)
        #expect(asked.minimum >= DisplayClock.slowestLinkHertz && asked.minimum == 20)
        // The link fires at the rate it was asked for; the stall deadline passes every 100 ms.
        let interval = 1 / Double(asked.preferred ?? asked.minimum)
        var nextFrame = interval
        for tenth in 1...20 {
            let deadline = Double(tenth) / 10
            while nextFrame <= deadline + 1e-9 {
                now = nextFrame
                displays.displayDidFire(1, timestamp: now, refreshInterval: interval)
                nextFrame += interval
            }
            now = deadline
            displays.stallTimerFired(1)
        }
        #expect(displays.lastStall(on: 1) == nil, "a running slow link is not a stall")
        #expect(displays.linksMade == 1, "and is never rebuilt")
        dots.deactivate()
    }

    /// Every existing client keeps the motion rate: the default, budgeted batches and view clients.
    @Test func clientsDefaultToMotion() {
        let displays = DisplayClock(makeLink: RateLinks().make, displayOf: { _ in 1 }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "w", host: .screen, displays: displays, budget: nil)
        let work = MainWorkScheduler(budget: MainFrameBudget(uptimeNanos: { 1_000_000_000 }), displays: displays)
        let plain = FrameClient(owner: "plain", on: scheduler) { _ in false }
        let batch = FrameClient(owner: "batch", isAnimation: false, on: scheduler) { _ in false }
        let budgeted = FrameClient(owner: "budgeted", budgeted: .automation, on: work) { _, _ in false }
        let view = FrameClient(owner: "view", view: NSView()) { _ in false }
        #expect([plain, batch, budgeted, view].allSatisfy { $0.rate == .motion })
    }

    @Test func ratesOrderAndClamp() {
        #expect(FrameRate.highest(of: [.ambient, .slow(8), .ui]) == .ui)
        #expect(FrameRate.highest(of: [.ambient, .motion]) == .motion)
        #expect(FrameRate.highest(of: []) == nil)
        #expect(FrameRate.slow(0).hertz == 1)
        #expect(FrameRate.slow(90).hertz == 30)
        #expect(FrameRate.motion.range.minimum == 80)
        // A slow rate may run faster, never slower.
        #expect(FrameRate.slow(8).range.minimum == 8 && FrameRate.slow(8).range.maximum == 30)
        // Two frames a step: a step boundary that drifts past a frame never hides a step.
        #expect(FrameRate.stepping(8, every: 1) == .slow(16))
        #expect(FrameRate.stepping(6, every: 0.8) == .slow(15))
        #expect(FrameRate.stepping(12, every: 0.8) == .ambient)
        #expect(FrameRate.stepping(60, every: 1) == .ambient)
        // A link never runs below two frames per stall deadline.
        #expect(DisplayClock.linkRange(.slow(5)).minimum == 20 && DisplayClock.linkRange(.slow(5)).maximum == 30)
        #expect(DisplayClock.linkRange(.ambient).minimum == 30)
        #expect(FrameRate.stepping(8, every: 0) == .ambient)
    }
}

extension DisplayClock {
    /// `frames` link frames of `display` at 120 Hz, the first `1 / 120` s after `start`.
    fileprivate func fire(_ display: CGDirectDisplayID, frames: Int, from start: CFTimeInterval = 0) {
        for frame in 0..<max(frames, 0) {
            displayDidFire(display, timestamp: start + Double(frame + 1) / 120, refreshInterval: 1.0 / 120)
        }
    }
}

/// A link that records the rates it was asked for.
@MainActor
private final class RateLink: FrameLink {
    var isPaused = false
    private(set) var requested: [CAFrameRateRange] = []
    func invalidate() {}
    func requestFrameRate(_ range: CAFrameRateRange) { requested.append(range) }
}

@MainActor
private final class RateLinks {
    private(set) var made: [RateLink] = []
    var make: DisplayClock.LinkFactory {
        { [self] _, _ in
            let link = RateLink()
            made.append(link)
            return link
        }
    }
}

extension NSWindow {
    @MainActor
    fileprivate static func rateFixture() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
