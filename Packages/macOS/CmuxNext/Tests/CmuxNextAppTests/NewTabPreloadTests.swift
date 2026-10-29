import AppKit
@testable import CmuxNextApp
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextMemory
import CmuxNextPages
import Foundation
import Testing

/// The New Tab page on the app's one preload slot: when the preload is made (the
/// launch's at 250 ms, cx-ec99; later ones after quiet input; none while held,
/// or under memory pressure), the take in the open's turn, the
/// recycle of a closed page, and that New Tab never evicts another page from the one slot.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabPreloadTests {
    /// Another page held by the slot (Settings): it never answers, so it stays held.
    @MainActor private final class OtherPage: PreloadablePage {
        let preloadView = NSView()
        var closed = false
        var preloadTraceID: UInt64 { 1 }
        func preloadWhenPainted(_ body: @escaping @MainActor () -> Void) {}
        func preloadCaptureCover(_ body: @escaping @MainActor (CGImage?) -> Void) {}
        func preloadSetVisible(_ visible: Bool) {}
        func preloadFreeze() -> Bool { false }
        func preloadThaw() {}
        func close() { closed = true }
    }

    @MainActor private final class Parking: PreloadParking {
        func hold(_ view: NSView, at size: NSSize) { view.setFrameSize(size) }
    }

    /// A slot on the app's deadline scheduler, rendered-parked as the app's.
    private static func slot(_ services: AppServices) -> PagePreloadSlot {
        PagePreloadSlot(parkState: .renderedParked, deadlines: services.mainDeadlines)
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
            let rig = MainDeadlineRig()
            let pool = NewTabPreload(services: services, slot: Self.slot(services),
                                     memory: services.memoryCoordinator, input: tap, deadlines: rig.deadlines)
            pool.webKit.markSlow() // the warm makes no web view: this test is about when it runs
            let window = Self.window()
            defer { window.close() }
            pool.retarget(window) // the launch warm, 250 ms out
            #expect(tap.liveSubscriptions == 1)
            #expect(tap.classes == [.key, .button, .scroll])
            rig.advance(by: .milliseconds(200))
            tap.deliver(InputEventRecord(type: .keyDown, timestamp: 1)) // the warm moves to 950 ms
            #expect(tap.liveSubscriptions == 1, "the key-down ended the warm's wait")
            tap.deliver(InputEventRecord(type: .keyUp, timestamp: 2)) // a re-arm here would move it to 1050 ms
            rig.fireAndRun()
            #expect(tap.liveSubscriptions == 0, "the warm did not run and drop the subscription")
            #expect(rig.elapsed >= 0.95 && rig.elapsed < 1.05, "the warm ran at \(rig.elapsed) s, not 950 ms after launch")
        }
    }

    /// The launch posts the hooks after the first frame and the warm at afterStartup.
    @Test func aHeldStartMakesNoPreloadUntilWarmingStarts() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-hooks")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tap = FakeInputTap()
            let pool = NewTabPreload(services: services, slot: Self.slot(services),
                                     memory: services.memoryCoordinator, input: tap, deadlines: MainDeadlineRig().deadlines)
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
            let pool = NewTabPreload(services: services, slot: Self.slot(services),
                                     memory: memory, input: tap, deadlines: MainDeadlineRig().deadlines)
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

            kernel.send(.critical)
            #expect(tap.liveSubscriptions == 0, "a warm was armed at critical")

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
            let slot = Self.slot(services)
            let other = OtherPage()
            let parking = Parking()
            let held = slot.preload(PagePreloadSlot.Key("settings"), size: NSSize(width: 400, height: 300), in: parking) { _ in other }
            #expect(held)
            let tap = FakeInputTap()
            let pool = NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: tap, deadlines: MainDeadlineRig().deadlines)
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
            let slot = Self.slot(services)
            let tap = FakeInputTap()
            let rig = MainDeadlineRig()
            let pool = NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: tap, deadlines: rig.deadlines)
            pool.webKit.request = {}
            pool.webKit.probe {}
            // The probe's answer is a background task: it lands in a frame of the rig.
            await Self.turns {
                rig.frame()
                return pool.webKit.state == .ready
            }
            try #require(pool.webKit.state == .ready)
            let window = Self.window()
            defer { window.close() }
            pool.retarget(window)
            rig.fireAndRun() // the launch warm, 250 ms out
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
            rig.fireAndRun() // the quiet-input warm
            await Self.turns { slot.count == 1 }
            #expect((slot.page as? AgentPanePreloadPage)?.pane === held, "the recycled page did not go back to the slot")
            pool.dropAll()
            #expect(slot.count == 0)
        }
    }

    /// New Tab is the slot's default preload: when another page leaves the slot (claimed or
    /// dropped), New Tab arms its own warm, so the next Cmd-T does not load cold.
    @Test func anotherPageLeavingTheSlotArmsTheNewTabWarm() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-emptied")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let slot = Self.slot(services)
            let settings = PagePreloadSlot.Key("settings")
            let other = OtherPage()
            #expect(slot.preload(settings, size: NSSize(width: 400, height: 300), in: Parking()) { _ in other })
            let tap = FakeInputTap()
            let pool = NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: tap, deadlines: MainDeadlineRig().deadlines)
            pool.webKit.markSlow()
            let window = Self.window()
            defer { window.close() }
            pool.retarget(window)
            #expect(tap.liveSubscriptions == 0, "a warm was armed while the slot holds another page")
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            #expect(slot.claim(settings, into: container, frame: container.bounds) != nil)
            #expect(slot.count == 0)
            #expect(tap.liveSubscriptions == 1, "the slot emptied and New Tab armed no warm")
        }
    }

    /// The held page follows the key main window: the same view moves into the new window's parking
    /// (a reparent, no reload) and stays in the slot.
    @Test func theHeldPageFollowsTheKeyWindowWithoutAReload() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-retarget")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let slot = Self.slot(services)
            let tap = FakeInputTap()
            let rig = MainDeadlineRig()
            let pool = NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: tap, deadlines: rig.deadlines)
            pool.webKit.request = {}
            pool.webKit.probe {}
            // The probe's answer is a background task: it lands in a frame of the rig.
            await Self.turns {
                rig.frame()
                return pool.webKit.state == .ready
            }
            try #require(pool.webKit.state == .ready)
            let first = Self.window(), second = Self.window()
            defer {
                first.close()
                second.close()
            }
            pool.retarget(first)
            rig.fireAndRun() // the launch warm, 250 ms out
            await Self.turns { slot.count == 1 }
            let held = try #require(pool.spareView)
            #expect(held.window === first)

            pool.retarget(second)
            #expect(pool.target === second)
            #expect((slot.page as? AgentPanePreloadPage)?.pane === held, "the move made another page")
            #expect(held.window === second, "the page stayed in the old window")
            #expect(held.superview is PagePreloadParkingView)
            #expect(pool.lastRetargetMilliseconds != nil)
            pool.dropAll()
        }
    }

    /// The New Tab pane as a preloadable page: by default it parks rendering (no hide, no slot
    /// cover); with `newTabParksHidden` its page view hides and shows again. No engine freezes it yet.
    @Test func theNewTabPageParksRenderingUnlessItParksHidden() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-preload-page")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let view = try #require(services.agentTabs.makeSpare(NewTabPage.sparePage(services)))
            defer { view.close() }
            // The page view (`PageWebView`): what the engines read visibility from.
            let pageView: NSView = view.page

            let rendering = AgentPanePreloadPage(pane: view, parksHidden: false)
            #expect(rendering.preloadView === view)
            #expect(!rendering.preloadFreeze(), "a freeze no engine performs")
            rendering.preloadSetVisible(false)
            #expect(!pageView.isHidden, "a page that parks rendering was hidden")
            var answered = false, cover: CGImage?
            rendering.preloadCaptureCover { image in
                answered = true
                cover = image
            }
            #expect(answered && cover == nil, "a page that parks rendering gave the slot a cover")

            let hidden = AgentPanePreloadPage(pane: view, parksHidden: true)
            #expect(!hidden.preloadFreeze(), "a freeze no engine performs")
            hidden.preloadSetVisible(false)
            #expect(pageView.isHidden, "the page did not hide")
            #expect(!view.isHidden, "the pane itself hid: the slot's cover on it would not show")
            hidden.preloadSetVisible(true)
            #expect(!pageView.isHidden, "the page did not show again")
        }
    }

    /// `debug.new_tab` keeps every field of the spare pool's report and adds the opening's `covered`.
    @Test func debugNewTabKeepsItsFields() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.newTabSpares.record(.init(spare: true, crossWindow: false, milliseconds: 1, covered: true))
            let state = try #require(await DebugNewTab.handle(["action": .string("state")], services).objectValue)
            for key in ["spares", "openings", "target_window", "last_retarget_ms", "last_recycle_refusal", "omnibar_tabs", "omnibar_workspaces"] {
                #expect(state[key] != nil, "debug.new_tab lost \(key)")
            }
            let opening = try #require(state["openings"]?.arrayValue?.last?.objectValue)
            #expect(Set(opening.keys) == ["spare", "cross_window", "refit", "covered", "ms"])
            #expect(opening["covered"] == .bool(true))
        }
    }
}
