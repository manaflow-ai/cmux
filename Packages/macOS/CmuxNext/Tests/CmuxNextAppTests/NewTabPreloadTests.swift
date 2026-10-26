import AppKit
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextMemory
import CmuxNextPages
import CmuxNextWakeupsTestSupport
import Foundation
import Testing

/// The New Tab page on the app's one preload slot (p13-webui-044): when the preload is made (the
/// launch's at 250 ms, cx-ec99; later ones after quiet input, p04-input-012; none while held,
/// p08-startup-017, or under memory pressure, p07-memory-047), the take in the open's turn, the
/// recycle of a closed page, and that New Tab never evicts another page from the one slot.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabPreloadTests {
    /// Another page held by the slot (Settings, p13-webui-045): it never answers, so it stays held.
    @MainActor private final class OtherPage: PreloadablePage {
        let preloadView = NSView()
        var closed = false
        var preloadTraceID: UInt64 { 1 }
        func preloadWhenPainted(_ body: @escaping @MainActor () -> Void) {}
        func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void) {}
        func preloadSetVisible(_ visible: Bool) {}
        func preloadFreeze() {}
        func preloadThaw() {}
        func close() { closed = true }
    }

    @MainActor private final class Parking: PreloadParking {
        func hold(_ view: NSView, at size: NSSize) { view.setFrameSize(size) }
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Runs main-actor turns until `done` or a bounded number of turns passed.
    private static func turns(until done: () -> Bool) async {
        for _ in 0..<2_000 where !done() { await Task.yield() }
    }

    @Test func aKeyDownPushesTheWarmBackAndAKeyUpDoesNot() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-input")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tap = FakeInputTap()
            let clock = ManualClock()
            let pool = NewTabPreload(services: services, slot: PagePreloadSlot(parkState: .renderedParked),
                                     memory: services.memoryCoordinator, input: tap, clock: clock)
            pool.webKit.markSlow() // the warm makes no web view: this test is about when it runs
            let window = Self.window()
            defer { window.close() }
            pool.retarget(window) // the launch warm, 250 ms out
            #expect(tap.liveSubscriptions == 1)
            #expect(tap.classes == [.key, .button, .scroll])
            try await clock.waitForSleeper()
            clock.advance(by: .milliseconds(200))
            tap.deliver(InputEventRecord(type: .keyDown, timestamp: 1)) // the warm moves to 950 ms
            try await clock.waitForSleeper()
            clock.advance(by: .milliseconds(100))
            for _ in 0..<50 { await Task.yield() }
            #expect(tap.liveSubscriptions == 1, "the key-down pushed the 250 ms warm back")
            tap.deliver(InputEventRecord(type: .keyUp, timestamp: 2)) // a re-arm here would move it to 1050 ms
            clock.advance(by: .milliseconds(660))
            await Self.turns { tap.liveSubscriptions == 0 }
            #expect(tap.liveSubscriptions == 0, "the warm ran at 950 ms and dropped the subscription")
        }
    }

    /// p08-startup-017: the launch posts the hooks after the first frame and the warm at afterStartup.
    @Test func aHeldStartMakesNoPreloadUntilWarmingStarts() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-hooks")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tap = FakeInputTap()
            let pool = NewTabPreload(services: services, slot: PagePreloadSlot(parkState: .renderedParked),
                                     memory: services.memoryCoordinator, input: tap, clock: ManualClock())
            pool.webKit.markSlow()
            let window = Self.window()
            defer { window.close() }
            pool.start(holdingWarm: true)
            #expect(services.agentTabs.takeSpare != nil, "Cmd-T and Cmd-N find the hooks")
            pool.retarget(window)
            #expect(pool.target === window, "the preload's window is known")
            #expect(tap.liveSubscriptions == 0, "no warm is armed before startWarming")
            pool.startWarming()
            #expect(tap.liveSubscriptions == 1, "the launch warm is armed")
        }
    }

    /// Chrome's spare rule: a warning cancels the armed warm and arms none, a take arms no refill,
    /// and back at normal the warm is armed again.
    @Test func noWarmUnderPressureAndTheWarmReturnsAtNormal() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-pressure")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let kernel = ManualMemoryPressureSource()
            let pressure = MemoryPressureEvents(source: kernel)
            let memory = MemoryCoordinator(pressure: pressure, mode: .medium, slicer: BrowserHibernationPressureTests.HeldSlices())
            let tap = FakeInputTap()
            let pool = NewTabPreload(services: services, slot: PagePreloadSlot(parkState: .renderedParked),
                                     memory: memory, input: tap, clock: ManualClock())
            pool.webKit.markSlow()
            let window = Self.window()
            defer { window.close() }
            pool.retarget(window)
            #expect(pool.allowsSpare, "medium mode at normal must keep one preload")
            #expect(tap.liveSubscriptions == 1, "medium mode at normal arms the warm")

            kernel.send(.warning)
            #expect(!pool.allowsSpare)
            #expect(tap.liveSubscriptions == 0, "a warning must cancel the armed warm")
            #expect(pool.spareView == nil)
            _ = pool.take(for: window, size: nil)
            #expect(tap.liveSubscriptions == 0, "a take at warning armed a refill")

            kernel.send(.normal)
            #expect(pool.allowsSpare)
            #expect(tap.liveSubscriptions == 1, "back at normal the warm is armed again")
            withExtendedLifetime(pressure) {}
        }
    }

    /// The slot holds one page for the app: while it holds another page, New Tab arms no warm and
    /// recycles nothing, and its drop leaves that page alone.
    @Test func anotherHeldPageIsNeverEvicted() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-other")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let slot = PagePreloadSlot(parkState: .renderedParked)
            let other = OtherPage()
            let parking = Parking()
            let held = slot.preload(PagePreloadSlot.Key("settings"), size: NSSize(width: 400, height: 300), in: parking) { _ in other }
            #expect(held)
            let tap = FakeInputTap()
            let pool = NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: tap, clock: ManualClock())
            let window = Self.window()
            defer { window.close() }
            pool.retarget(window)
            #expect(tap.liveSubscriptions == 0, "a warm was armed while the slot holds another page")
            #expect(pool.take(for: window, size: nil) == nil)
            let closed = try #require(services.agentTabs.makeSpare(NewTabPage.sparePage(services)))
            defer { closed.close() }
            #expect(!pool.recycle(closed))
            #expect(pool.lastRecycleRefusal == "slot full")
            pool.dropAll()
            #expect(slot.key == PagePreloadSlot.Key("settings") && !other.closed, "New Tab's drop closed another page")
        }
    }

    /// The launch's preload goes into the slot at 250 ms, Cmd-T takes it out in the open's turn at
    /// the size it waited at, and the closed page goes back to the slot at the next quiet moment.
    @Test func theSlotHoldsTheNewTabPageAndTheTakeEmptiesIt() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-take")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let slot = PagePreloadSlot(parkState: .renderedParked)
            let tap = FakeInputTap()
            let clock = ManualClock()
            let pool = NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: tap, clock: clock)
            pool.webKit.request = {}
            pool.webKit.probe {}
            await Self.turns { pool.webKit.state == .ready }
            try #require(pool.webKit.state == .ready)
            let window = Self.window()
            defer { window.close() }
            pool.retarget(window)
            try await clock.waitForSleeper()
            clock.advance(by: NewTabPreload.launchDelay)
            await Self.turns { slot.count == 1 }
            #expect(slot.key == NewTabPreload.key, "the launch warm did not preload New Tab")
            let held = try #require(pool.spareView)
            #expect(held.superview is PagePreloadParkingView)

            let size = NSSize(width: 400, height: 300)
            let taken = try #require(pool.take(for: window, size: size))
            #expect(taken.view === held)
            #expect(slot.count == 0, "the take left the page in the slot")
            #expect(!taken.refit, "the page waited at another size than its pane's")
            #expect(pool.openingSize(of: held) == size)

            #expect(pool.recycle(held), "refused: \(pool.lastRecycleRefusal ?? "?")")
            #expect(held.superview == nil, "a recycled page stays out of the window until a quiet moment")
            try await clock.waitForSleeper()
            clock.advance(by: NewTabPreload.idleInput)
            await Self.turns { slot.count == 1 }
            #expect(slot.page === held, "the recycled page did not go back to the slot")
            pool.dropAll()
            #expect(slot.count == 0)
        }
    }
}
