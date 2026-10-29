import AppKit
import CmuxNextWakeupsTestSupport
@testable import CmuxNextWakeups
import QuartzCore
import Testing

/// An occluded window makes no frames. Its ``WindowOcclusionFamily`` tells the
/// content producers first (the window's scheduler parks its animation clients, so the window holds no
/// display subscription and gets no ticks), then diagnostics; the window seen again restores them in one
/// step. The fake signal is the family's own setter, which the app's checker drives.
@MainActor @Suite(.timeLimit(.minutes(1))) struct WindowOcclusionFamilyTests {
    let window: NSWindow
    let links: CountingLinks
    let displays: DisplayClock

    init() {
        let links = CountingLinks()
        // The system says the window can be seen: only the family occludes it.
        displays = DisplayClock(makeLink: links.make, displayOf: { _ in 1 }, isVisible: { _ in true }, clock: ManualClock())
        self.links = links
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
    }

    /// A window scheduler on the test clock that follows `family`.
    func makeScheduler(following family: WindowOcclusionFamily) -> FrameScheduler {
        let scheduler = FrameScheduler(name: "w", host: .window(window), displays: displays, budget: nil)
        scheduler.follow(family)
        return scheduler
    }

    @Test func contentSubscribersHearAFlipBeforeDiagnostics() {
        let family = WindowOcclusionFamily(window: window)
        var heard: [String] = []
        let diagnostics = family.subscribe(.diagnostics, owner: "monitor") { heard.append("monitor \($0)") }
        let content = family.subscribe(.content, owner: "surface") { heard.append("surface \($0)") }
        family.set(occluded: true)
        family.set(occluded: true)
        #expect(heard == ["surface true", "monitor true"], "content first, and a repeat is no flip")
        #expect(family.subscribers == ["surface", "monitor"])
        content.cancel()
        family.set(occluded: false)
        #expect(heard == ["surface true", "monitor true", "monitor false"])
        #expect(family.flips == 2)
        withExtendedLifetime(diagnostics) {}
    }

    @Test func aFamilyIsMadeOnceAndKeptByItsWindow() {
        #expect(WindowOcclusionFamily.installed(on: window) == nil)
        let family = WindowOcclusionFamily.of(window)
        #expect(WindowOcclusionFamily.of(window) === family)
        #expect(WindowOcclusionFamily.installed(on: window) === family)
    }

    /// The acceptance: occluded, the window's animation gets 0 ticks and its scheduler 0 display
    /// subscriptions (the display drops its link); seen again, one restore and it ticks from the next frame.
    @Test func anOccludedWindowHasNoTicksAndNoSubscription() {
        let family = WindowOcclusionFamily(window: window)
        let scheduler = makeScheduler(following: family)
        var ticks = 0
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in
            ticks += 1
            return true
        }
        spring.activate()
        displays.displayDidFire(1, timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(ticks == 1)
        #expect(displays.subscribers(on: 1) == ["w"])

        family.set(occluded: true)
        #expect(scheduler.isWindowOccluded)
        #expect(displays.subscribers(on: 1).isEmpty, "0 vsync subscriptions")
        #expect(displays.liveLinks == 0)
        #expect(scheduler.occludedClients == ["spring"])
        #expect(spring.isActive, "the spring still runs; it only waits off the link")
        displays.displayDidFire(1, timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(ticks == 1, "0 ticks while occluded")

        family.set(occluded: false)
        #expect(scheduler.occlusionRestores == 1)
        #expect(scheduler.occludedClients.isEmpty)
        #expect(displays.subscribers(on: 1) == ["w"])
        displays.displayDidFire(1, timestamp: 3, refreshInterval: 1.0 / 60)
        #expect(ticks == 2)
        family.set(occluded: false)
        #expect(scheduler.occlusionRestores == 1, "one restore per return to visible")
        spring.deactivate()
        #expect(displays.liveLinks == 0)
    }

    /// An animation that starts while its window is occluded waits off the link; one that ends while
    /// waiting is dropped and never comes back.
    @Test func anAnimationStartedWhileOccludedWaits() {
        let family = WindowOcclusionFamily(window: window)
        let scheduler = makeScheduler(following: family)
        family.set(occluded: true)
        let fade = FrameClient(owner: "fade", on: scheduler) { _ in true }
        let pulse = FrameClient(owner: "pulse", on: scheduler) { _ in true }
        fade.activate()
        pulse.activate()
        #expect(displays.subscribers(on: 1).isEmpty)
        #expect(links.made == 0)
        #expect(scheduler.occludedClients == ["fade", "pulse"])
        pulse.deactivate()
        family.set(occluded: false)
        #expect(scheduler.activeClients == ["fade"])
        fade.deactivate()
    }

    /// Batch work someone waits for (`isAnimation: false`) keeps ticking in an occluded window, at the
    /// stall rate of a window nobody sees: the display's link pauses.
    @Test func batchWorkGoesOnOffTheLink() throws {
        let family = WindowOcclusionFamily(window: window)
        let scheduler = makeScheduler(following: family)
        var drains = 0
        let drain = FrameClient(owner: "drain", isAnimation: false, on: scheduler) { _ in
            drains += 1
            return true
        }
        drain.activate()
        family.set(occluded: true)
        #expect(scheduler.occludedClients.isEmpty)
        #expect(displays.subscribers(on: 1) == ["w"])
        displays.displayDidFire(1, timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(drains == 1, "its first frame is due at once")
        #expect(try #require(links.last).isPaused, "only a window nobody sees is left: the link stops")
        displays.displayDidFire(1, timestamp: 1 + 1.0 / 60, refreshInterval: 1.0 / 60)
        #expect(drains == 1, "then the stall rate, not every vsync")
        drain.deactivate()
    }

    /// A closed window's scheduler lets go of its waiting clients without calling back.
    @Test func invalidatingDropsWaitingClients() {
        let family = WindowOcclusionFamily(window: window)
        let scheduler = makeScheduler(following: family)
        let spring = FrameClient(owner: "spring", on: scheduler) { _ in true }
        spring.activate()
        family.set(occluded: true)
        scheduler.invalidate()
        #expect(!spring.isActive)
        #expect(scheduler.occludedClients.isEmpty)
        family.set(occluded: false)
        #expect(displays.subscribers(on: 1).isEmpty)
    }
}

/// A link that records whether it is paused.
@MainActor
final class CountingLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

@MainActor
final class CountingLinks {
    private(set) var made = 0
    private(set) var last: CountingLink?
    var make: DisplayClock.LinkFactory {
        { [self] _, _ in
            made += 1
            let link = CountingLink()
            last = link
            return link
        }
    }
}
