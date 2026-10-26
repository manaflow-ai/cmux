import AppKit
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// DisplayClock (p03-rendering-010): one display link per display, shared by every FrameScheduler on
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
        #expect(fixture.schedulers.allSatisfy(\.hasLink))

        for client in clients.dropLast() { client.deactivate() }
        #expect(displays.liveLinks == 1, "a client is still active")
        clients.last?.deactivate()
        #expect(displays.liveLinks == 0, "no client: no link")
        #expect(links.made.first?.invalidated == true)
        #expect(displays.subscribers(on: 1).isEmpty)
        #expect(!fixture.schedulers.contains(where: \.hasLink))
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
