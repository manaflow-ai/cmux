import AppKit
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// DisplayClock: one display link per display, shared by every FrameScheduler on
/// it, as Chrome's `DisplayLinkMac::GetForDisplay` (ui/display/mac/display_link_mac.h). Before it,
/// every window, the app scheduler and the budgeted scheduler each made their own link: up to three
/// links (and three main-thread wakes a frame) for one window on one display.
@MainActor @Suite(.timeLimit(.minutes(1))) struct DisplayClockTests {
    /// Two window schedulers, the app's and the budgeted one on one display make one link; it goes
    /// away when the last client goes idle.
    @Test func twoWindowsAppAndBudgetedOnOneDisplayMakeOneLink() {
        let links = FakeLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let fixture = Fixture(displays: displays)
        let clients = fixture.clients { _ in true }
        for client in clients { client.activate() }

        #expect(displays.linksMade == 1, "made \(displays.linksMade) links for 4 schedulers on one display")
        #expect(links.made.count == 1)
        #expect(displays.liveLinks == 1)
        #expect(displays.subscribers(on: 1).count == 4)
        let everyLinked = fixture.schedulers.allSatisfy { $0.hasLink }
        #expect(everyLinked)

        for client in clients.dropLast() { client.deactivate() }
        #expect(displays.liveLinks == 1, "a client is still active")
        clients.last?.deactivate()
        #expect(displays.liveLinks == 0, "no client: no link")
        #expect(links.made.first?.invalidated == true)
        #expect(displays.subscribers(on: 1).isEmpty)
        let anyLinked = fixture.schedulers.contains { $0.hasLink }
        #expect(!anyLinked)
    }

    /// One tick reaches the budget holder's frame-locked clients first, then the other schedulers
    /// on the display, then the budgeted classes.
    @Test func aTickGoesToFrameLockedThenWindowsThenBudgeted() {
        let displays = DisplayClock(makeLink: FakeLinks().make, displayOf: { _ in 1 }, clock: ManualClock())
        let fixture = Fixture(displays: displays)
        var order: [String] = []
        // Subscribe the windows and the app before the budget holder: delivery order is not
        // subscription order.
        let window = FrameClient(owner: "window", on: fixture.windowA) { _ in order.append("window"); return false }
        let app = FrameClient(owner: "app", on: fixture.app) { _ in order.append("app"); return false }
        let budgeted = FrameClient(owner: "budgeted", budgeted: .automation, on: fixture.work) { _, _ in
            order.append("budgeted")
            return false
        }
        let drain = FrameClient(owner: "drain", on: fixture.work.frames) { _ in order.append("drain"); return false }
        for client in [window, app, budgeted, drain] { client.activate() }

        displays.displayDidFire(1, timestamp: 10, refreshInterval: 1.0 / 60)

        #expect(order == ["drain", "window", "app", "budgeted"])
        #expect(displays.liveLinks == 0, "every client went idle on the tick: the link is gone")
    }

    /// Windows on two displays get one link each, and a display's tick reaches only its own
    /// schedulers.
    @Test func eachDisplayHasItsOwnLink() {
        let links = FakeLinks()
        let left = NSWindow.fixture(), right = NSWindow.fixture()
        let displays = DisplayClock(makeLink: links.make, displayOf: { $0 === right ? 2 : 1 }, clock: ManualClock())
        let onLeft = FrameScheduler(name: "left", host: .window(left), displays: displays, budget: nil)
        let onRight = FrameScheduler(name: "right", host: .window(right), displays: displays, budget: nil)
        var ticks: [String] = []
        let leftClient = FrameClient(owner: "left", on: onLeft) { _ in ticks.append("left"); return true }
        let rightClient = FrameClient(owner: "right", on: onRight) { _ in ticks.append("right"); return true }
        leftClient.activate()
        rightClient.activate()

        #expect(displays.linksMade == 2)
        displays.displayDidFire(2, timestamp: 1, refreshInterval: 1.0 / 120)
        #expect(ticks == ["right"])

        leftClient.deactivate()
        #expect(displays.liveLinks == 1, "display 1 went idle, display 2 still ticks")
        #expect(!displays.hasLink(1) && displays.hasLink(2))
        rightClient.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// The vsync grid of a time is the display's own (p03-rendering 004): a 120 Hz and a 60 Hz display that both
    /// tick give each window its display's last tick, the key window's display with no window, never the one that
    /// ticked last. With no screen at all the newest tick of any display is a grid that is never running.
    @Test func newestFrameIsTheDisplaysOwnGrid() throws {
        let left = NSWindow.fixture(), right = NSWindow.fixture()
        var key: CGDirectDisplayID? = 2
        let displays = DisplayClock(makeLink: FakeLinks().make, displayOf: { window in
            window.map { $0 === right ? 2 : 1 } ?? key
        }, clock: ManualClock())
        let onLeft = FrameScheduler(name: "left", host: .window(left), displays: displays, budget: nil)
        let onRight = FrameScheduler(name: "right", host: .window(right), displays: displays, budget: nil)
        let leftClient = FrameClient(owner: "left", on: onLeft) { _ in true }
        let rightClient = FrameClient(owner: "right", on: onRight) { _ in true }
        leftClient.activate()
        rightClient.activate()
        defer {
            leftClient.deactivate()
            rightClient.deactivate()
        }
        displays.displayDidFire(1, timestamp: 5, refreshInterval: 1.0 / 120)
        displays.displayDidFire(2, timestamp: 4.99, refreshInterval: 1.0 / 60)

        let onOne = try #require(displays.newestFrame(for: left))
        #expect(onOne.timestamp == 5 && onOne.interval == 1.0 / 120 && onOne.linkRunning)
        let onTwo = try #require(displays.newestFrame(for: right))
        #expect(onTwo.timestamp == 4.99 && onTwo.interval == 1.0 / 60 && onTwo.linkRunning, "not the newer 120 Hz tick")
        #expect(displays.newestFrame() == onTwo, "no window: the key window's display")

        key = 3
        #expect(displays.newestFrame() == nil, "a display with no tick yet has no grid")
        key = nil
        let anyDisplay = try #require(displays.newestFrame())
        #expect(anyDisplay.timestamp == 5 && !anyDisplay.linkRunning, "no screen: another display's grid, not running")
    }

    /// A display runs one stall timer for all its schedulers: a second of frames with four
    /// schedulers ticking arms it once.
    @Test func oneStallTimerPerDisplay() {
        let displays = DisplayClock(makeLink: FakeLinks().make, displayOf: { _ in 1 }, clock: ManualClock())
        let fixture = Fixture(displays: displays)
        let clients = fixture.clients { _ in true }
        for client in clients { client.activate() }
        for frame in 1...120 {
            displays.displayDidFire(1, timestamp: Double(frame) / 120, refreshInterval: 1.0 / 120)
        }
        #expect(displays.stallTimerArms(on: 1) == 1, "armed \(displays.stallTimerArms(on: 1)) times")
        #expect(fixture.schedulers.allSatisfy { $0.stallTimerArms == 1 })
        for client in clients { client.deactivate() }
    }

    /// A scheduler that joins a display whose link already runs makes no link, and its ticks carry
    /// its own elapsed time.
    @Test func aLaterSchedulerJoinsTheRunningLink() {
        let links = FakeLinks()
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, clock: ManualClock())
        let fixture = Fixture(displays: displays)
        let first = FrameClient(owner: "first", on: fixture.windowA) { _ in true }
        first.activate()
        displays.displayDidFire(1, timestamp: 1, refreshInterval: 1.0 / 60)
        var elapsed: [Double] = []
        let second = FrameClient(owner: "second", on: fixture.windowB) { tick in elapsed.append(tick.rawElapsed); return true }
        second.activate()
        displays.displayDidFire(1, timestamp: 1 + 1.0 / 60, refreshInterval: 1.0 / 60)
        displays.displayDidFire(1, timestamp: 1 + 2.0 / 60, refreshInterval: 1.0 / 60)

        #expect(links.made.count == 1)
        #expect(fixture.windowA.linksMade == 1 && fixture.windowB.linksMade == 0)
        #expect(elapsed.count == 2)
        #expect(abs(elapsed[1] - 1.0 / 60) < 1e-9, "the second tick's elapsed is one frame")
        first.deactivate()
        second.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// No screen (a headless launch): no link, and the subscriber still ticks once on the next turn.
    @Test func noScreenTicksOnTheNextTurn() async {
        let displays = DisplayClock(makeLink: { _, _ in nil }, displayOf: { _ in nil }, clock: ManualClock())
        let scheduler = FrameScheduler(name: "headless", host: .screen, displays: displays, budget: nil)
        var ticks = 0
        let client = FrameClient(owner: "headless", on: scheduler) { _ in ticks += 1; return false }
        client.activate()
        #expect(displays.liveLinks == 0)
        for _ in 0..<100 where ticks == 0 { await Task.yield() }
        #expect(ticks == 1)
        #expect(displays.subscribers(on: DisplayClock.noDisplay).isEmpty, "the idle client left the display")
    }

    /// A display whose screen went away (an external monitor unplugged): its link stops and the
    /// rebuild cannot make one, so on its stall deadline its subscribers move to the display they are
    /// on now and tick on that display's link, not on the 100 ms deadline. The budget holder's window
    /// follows the link it ticks on.
    @Test func aGoneDisplayMovesItsSubscribersToTheirDisplayNow() {
        var gone: Set<CGDirectDisplayID> = []
        var main: CGDirectDisplayID = 1
        let links = FakeLinks()
        let media = TestMediaTime()
        let displays = DisplayClock(makeLink: { id, clock in gone.contains(id) ? nil : links.make(id, clock) },
                                    displayOf: { _ in main }, clock: ManualClock(), mediaTime: media.read)
        let fixture = Fixture(displays: displays)
        var ticks: [String] = []
        let app = FrameClient(owner: "app", on: fixture.app) { _ in ticks.append("app"); return true }
        let drain = FrameClient(owner: "drain", on: fixture.work.frames) { _ in ticks.append("drain"); return true }
        app.activate()
        drain.activate()
        #expect(fixture.work.budget.tickOwnsWindow)

        gone.insert(1)
        main = 2
        for _ in 0..<DisplayClock.stallsBeforeRebuild {
            media.now += 0.2
            displays.stallTimerFired(1)
        }

        #expect(displays.subscribers(on: 1).isEmpty)
        #expect(displays.subscribers(on: 2) == ["app", "budgeted"])
        #expect(!displays.hasLink(1) && displays.hasLink(2))
        #expect(fixture.app.hasLink && fixture.work.frames.hasLink)
        #expect(fixture.work.budget.tickOwnsWindow, "the drain ticks on display 2's link")
        ticks.removeAll()
        displays.displayDidFire(2, timestamp: media.now, refreshInterval: 1.0 / 60)
        #expect(ticks == ["drain", "app"])
        app.deactivate()
        drain.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// A window that went to another screen follows it, and when the main display changes the stall
    /// deadline moves every subscriber to the display it is on now.
    @Test func aScreenChangeMovesSubscribers() {
        let links = FakeLinks()
        var main: CGDirectDisplayID = 1
        var windowDisplay: CGDirectDisplayID = 1
        let displays = DisplayClock(makeLink: links.make, displayOf: { $0 == nil ? main : windowDisplay }, clock: ManualClock())
        let fixture = Fixture(displays: displays)
        let clients = fixture.clients { _ in true }
        for client in clients { client.activate() }

        windowDisplay = 3
        fixture.windowA.screenDidChange()
        #expect(displays.subscribers(on: 3) == ["window a"])
        #expect(displays.subscribers(on: 1) == ["window b", "app", "budgeted"])

        main = 2
        windowDisplay = 3
        displays.stallTimerFired(1)
        #expect(displays.subscribers(on: 1).isEmpty)
        #expect(!displays.hasLink(1), "nobody is left on display 1")
        #expect(displays.subscribers(on: 2) == ["app", "budgeted"])
        #expect(displays.subscribers(on: 3) == ["window a", "window b"])
        #expect(displays.liveLinks == 2)
        for client in clients { client.deactivate() }
        #expect(displays.liveLinks == 0)
    }

    /// A window moving between displays mid-animation.
    struct ScreenMove: Sendable, CustomStringConvertible {
        let description: String
        let oldInterval: Double
        let newInterval: Double
        /// Where the new display's refresh grid starts after the old one's.
        let newPhase: Double
        /// How late main runs the new display's link callbacks (main was busy).
        let newLag: Double
        /// When the window moves, after the old display's first frame.
        let moveAfter: Double
        /// Old-display ticks before the move.
        let ticksBefore: Int
        /// The first tick on the new display: the frame time of the new display's first frame that
        /// starts more than half its interval after the last old tick and is shown after it.
        let firstNewTick: Double

        static let all: [ScreenMove] = [
            ScreenMove(description: "60 to 120 Hz in phase", oldInterval: 1.0 / 60, newInterval: 1.0 / 120,
                       newPhase: 0, newLag: 0, moveAfter: 2.4 / 60, ticksBefore: 3, firstNewTick: 3.0 / 60),
            // The last 120 Hz tick starts at +8.3 ms and is shown at +16.7 ms; the 60 Hz frame that
            // starts at +5 ms (shown at +21.7 ms) runs on main after the move. Taking it would move
            // the tick time back 3.3 ms.
            ScreenMove(description: "120 to 60 Hz out of phase, new callbacks late", oldInterval: 1.0 / 120,
                       newInterval: 1.0 / 60, newPhase: 0.005, newLag: 0.005, moveAfter: 0.009, ticksBefore: 2,
                       firstNewTick: 0.005 + 1.0 / 60),
        ]
    }

    /// A window dragged mid-animation to a display with another refresh rate. Its
    /// WindowScreenFamily moves its scheduler on `didChangeScreen` (before it, the window ticked on
    /// the old display until a stall deadline): from then on it ticks only on the new display's link,
    /// its tick times never run back, no gap is longer than the old interval or one and a half new
    /// ones, and no refresh gets two of its frames (Chrome's `kDoubleTickDivisor` gate,
    /// components/viz/common/frame_sinks/begin_frame_source.cc). The new display already runs for
    /// another window, or gets its link with the move.
    @Test(arguments: ScreenMove.all, [true, false])
    func aWindowMovedMidAnimationTicksOnlyOnTheNewDisplay(move: ScreenMove, newDisplayRuns: Bool) {
        let links = FakeLinks()
        let media = TestMediaTime()
        let window = NSWindow.fixture(), other = NSWindow.fixture()
        var screen: CGDirectDisplayID = 1
        let displays = DisplayClock(makeLink: links.make, displayOf: { $0 === window ? screen : 2 },
                                    clock: ManualClock(), mediaTime: media.read)
        let center = NotificationCenter()
        let moving = FrameScheduler(name: "moving", host: .window(window), displays: displays, budget: nil)
        let family = WindowScreenFamily(window: window, scheduler: moving, center: center)
        var moved = false
        var ticks: [(tick: FrameTick, afterMove: Bool)] = []
        let spring = FrameClient(owner: "spring", on: moving) { tick in ticks.append((tick, moved)); return true }
        spring.activate()
        let onNew = FrameScheduler(name: "new", host: .window(other), displays: displays, budget: nil)
        let newWindow = FrameClient(owner: "new", on: onNew) { _ in true }
        if newDisplayRuns { newWindow.activate() }

        let start = 1.0, moveAt = start + move.moveAfter
        // Each display refreshes on its own grid; main runs a frame's callback at `runAt`.
        var events: [(runAt: Double, timestamp: Double, display: CGDirectDisplayID?)] = [(moveAt, moveAt, nil)]
        for frame in 0..<8 {
            let timestamp = start + Double(frame) * move.oldInterval
            events.append((timestamp, timestamp, 1))
        }
        for frame in 0..<8 {
            let timestamp = start + move.newPhase + Double(frame) * move.newInterval
            events.append((timestamp + move.newLag, timestamp, 2))
        }
        for event in events.sorted(by: { $0.runAt < $1.runAt }) {
            media.now = event.runAt
            guard let id = event.display else {
                screen = 2
                moved = true
                center.post(name: NSWindow.didChangeScreenNotification, object: window)
                continue
            }
            let interval = id == 1 ? move.oldInterval : move.newInterval
            displays.displayDidFire(id, timestamp: event.timestamp, refreshInterval: interval,
                                    targetTimestamp: event.timestamp + interval)
        }

        #expect(displays.subscribers(on: 1).isEmpty, "the moved window left the old display")
        #expect(displays.subscribers(on: 2).contains("moving"))
        #expect(!displays.hasLink(1), "nobody is left on the old display: its link is gone")
        let before = ticks.filter { !$0.afterMove }.map { $0.tick }, after = ticks.filter { $0.afterMove }.map { $0.tick }
        #expect(before.count == move.ticksBefore && before.allSatisfy { $0.refreshInterval == move.oldInterval })
        #expect(!after.isEmpty && after.allSatisfy { $0.refreshInterval == move.newInterval },
                "a tick after the move came from the old display's link")
        let maxGap = max(move.oldInterval, 1.5 * move.newInterval)
        let all = ticks.map { $0.tick }
        for (earlier, later) in zip(all, all.dropFirst()) {
            #expect(later.timestamp > earlier.timestamp,
                    "tick time ran back from \(earlier.timestamp) to \(later.timestamp)")
            #expect(later.timestamp - earlier.timestamp <= maxGap + 1e-9,
                    "\(later.timestamp - earlier.timestamp) s between ticks at \(earlier.timestamp) and \(later.timestamp)")
            #expect(later.targetTimestamp - earlier.targetTimestamp >= min(move.oldInterval, move.newInterval) / 2,
                    "two ticks shown on one refresh at \(later.targetTimestamp)")
        }
        #expect(after.first.map { abs($0.timestamp - (start + move.firstNewTick)) < 1e-9 } == true,
                "the first new-display tick was \(after.first?.timestamp ?? 0), not the first frame after the last old one")
        spring.deactivate()
        newWindow.deactivate()
        #expect(displays.liveLinks == 0)
        withExtendedLifetime((family, onNew)) {}
    }

    /// The link goes away while the budget holder stays subscribed (a stall rebuild that cannot
    /// make one): its ticks no longer own the budget's window, so off-tick work can roll it; a
    /// later retry that makes a link gives it back.
    @Test func losingTheLinkGivesUpTheBudgetWindow() {
        var linkless = false
        let links = FakeLinks()
        let media = TestMediaTime()
        let displays = DisplayClock(makeLink: { id, clock in linkless ? nil : links.make(id, clock) },
                                    displayOf: { _ in 1 }, clock: ManualClock(), mediaTime: media.read)
        let work = MainWorkScheduler(budget: MainFrameBudget(uptimeNanos: { 1_000_000_000 }), displays: displays)
        let drain = FrameClient(owner: "drain", on: work.frames) { _ in true }
        drain.activate()
        #expect(work.budget.tickOwnsWindow)

        linkless = true
        for _ in 0..<DisplayClock.stallsBeforeRebuild {
            media.now += 0.2
            displays.stallTimerFired(1)
        }
        #expect(!work.frames.hasLink)
        #expect(!work.budget.tickOwnsWindow, "no link: the budget's window rolls off-tick")

        linkless = false
        media.now += 0.2
        displays.stallTimerFired(1)
        #expect(work.frames.hasLink)
        #expect(work.budget.tickOwnsWindow, "the retry made a link")
        drain.deactivate()
    }

    /// A window nobody can see (occluded or miniaturized) gets no full-rate tick: once per stall
    /// timeout, and when it is the only subscriber the link stops and the deadline ticks it.
    @Test func anOccludedWindowGetsNoFullRateTick() {
        let links = FakeLinks()
        let media = TestMediaTime()
        let shown = NSWindow.fixture(), hidden = NSWindow.fixture()
        var hiddenIsVisible = false
        let displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 },
                                    isVisible: { $0 === shown || hiddenIsVisible }, clock: ManualClock(), mediaTime: media.read)
        let onShown = FrameScheduler(name: "shown", host: .window(shown), displays: displays, budget: nil)
        let onHidden = FrameScheduler(name: "hidden", host: .window(hidden), displays: displays, budget: nil)
        var shownTicks = 0, hiddenTicks = 0
        let shownClient = FrameClient(owner: "shown", on: onShown) { _ in shownTicks += 1; return true }
        let hiddenClient = FrameClient(owner: "hidden", on: onHidden) { _ in hiddenTicks += 1; return true }
        shownClient.activate()
        hiddenClient.activate()

        for frame in 0..<12 {
            displays.displayDidFire(1, timestamp: 1 + Double(frame) / 120, refreshInterval: 1.0 / 120)
        }
        #expect(shownTicks == 12)
        #expect(hiddenTicks == 1, "the occluded window ticked \(hiddenTicks) times in 92 ms of 120 Hz frames")
        displays.displayDidFire(1, timestamp: 1.1, refreshInterval: 1.0 / 120)
        #expect(hiddenTicks == 2, "a stall timeout after its last tick it ticks again")

        shownClient.deactivate()
        media.now = 1.1
        displays.displayDidFire(1, timestamp: 1.1 + 1.0 / 120, refreshInterval: 1.0 / 120)
        #expect(links.made.first?.isPaused == true, "only an occluded window is left: the link stops")
        let before = hiddenTicks
        media.now += 0.2
        displays.stallTimerFired(1)
        #expect(hiddenTicks == before + 1, "the stall deadline ticks it")
        #expect(displays.lastStall(on: 1) == nil, "a stopped link is not a stall")
        #expect(links.made.count == 1, "and not rebuilt")

        hiddenIsVisible = true
        media.now += 0.2
        displays.stallTimerFired(1)
        #expect(links.made.first?.isPaused == false, "it can be seen again: the link runs")
        hiddenClient.deactivate()
        #expect(displays.liveLinks == 0)
    }
}

/// Four schedulers on one display clock: two windows, the app's and the budget holder's.
@MainActor
private struct Fixture {
    /// The windows the window schedulers hold weakly.
    let windows: [NSWindow]
    let windowA: FrameScheduler
    let windowB: FrameScheduler
    let app: FrameScheduler
    let work: MainWorkScheduler

    init(displays: DisplayClock) {
        let windows = [NSWindow.fixture(), NSWindow.fixture()]
        self.windows = windows
        windowA = FrameScheduler(name: "window a", host: .window(windows[0]), displays: displays, budget: nil)
        windowB = FrameScheduler(name: "window b", host: .window(windows[1]), displays: displays, budget: nil)
        app = FrameScheduler(name: "app", host: .screen, displays: displays, budget: nil)
        work = MainWorkScheduler(budget: MainFrameBudget(uptimeNanos: { 1_000_000_000 }), displays: displays)
    }

    var schedulers: [FrameScheduler] { [windowA, windowB, app, work.frames] }

    /// One frame client on each scheduler.
    func clients(_ onFrame: @escaping @MainActor (FrameTick) -> Bool) -> [FrameClient] {
        schedulers.map { FrameClient(owner: $0.name, on: $0, onFrame: onFrame) }
    }
}

/// `CACurrentMediaTime` for the stall checks.
@MainActor
private final class TestMediaTime {
    var now: CFTimeInterval = 1000
    var read: @MainActor () -> CFTimeInterval { { [self] in now } }
}

@MainActor
private final class FakeLink: FrameLink {
    var isPaused = false
    private(set) var invalidated = false
    func invalidate() { invalidated = true }
}

@MainActor
private final class FakeLinks {
    private(set) var made: [FakeLink] = []
    var make: DisplayClock.LinkFactory {
        { [self] _, _ in
            let link = FakeLink()
            made.append(link)
            return link
        }
    }
}

extension NSWindow {
    @MainActor
    fileprivate static func fixture() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}
