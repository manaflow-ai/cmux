import AppKit
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import ObjectiveC
import Testing
@testable import CmuxNextBrowser

/// The CEF pump's input policy (plans/cmux-next/chrome-parity/p04-input.md, task 024): a due pass
/// waits while a person's input is pending, until that input's dispatch ends, the next frame deadline
/// or one refresh at most in a row; after input AppKit delivered to a Chromium page, a due pass runs
/// on the next run loop pass whatever is pending, because Chromium's input router and wheel acks run
/// inside `CefDoMessageLoopWork`. No pass ever runs inside an input's dispatch.
@MainActor
@Suite(.serialized) struct CEFPumpInputYieldTests {
    static let refresh: TimeInterval = 1.0 / 120

    @Test func noPendingInputRunsTheDuePassAsBefore() {
        let rig = Rig()
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 2, "the start's pass and the requested one")
        #expect(rig.pump.stats.deferredForInput == 0)
        #expect(rig.pump.stats.passesWhileInputPending == CEFPumpStats.PassesByTarget())
        #expect(rig.pump.stats.passTimes.count == 2)
    }

    @Test func pendingInputHoldsThePassUntilItsDispatchEnds() {
        let rig = Rig()
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 1, "the key waits in the queue: no pass before it")
        #expect(rig.pump.stats.deferredForInput == 1)
        #expect(rig.timer.armed.map { abs($0 - Self.refresh) < 1e-9 } == true, "armed at the one-refresh bound")
        #expect(rig.timer.tolerance == 0)
        // The key is dispatched to a terminal: nothing pending, the held pass runs on the next run loop pass.
        rig.clock.advance(by: .milliseconds(2))
        rig.pending.isPending = false
        rig.dispatches.end(.terminal)
        #expect(rig.passes == 1, "never inside another target's dispatch")
        #expect(rig.timer.armed == 0)
        rig.timer.fire()
        #expect(rig.passes == 2)
        #expect(rig.pump.stats.passesWhileInputPending.byName.values.allSatisfy { $0 == 0 },
                "DC2: no pass while input was pending")
        #expect(rig.pump.stats.deferredForInput == 1)
    }

    /// The bound holds across a stream of input: a later dispatch does not start the wait over, so
    /// the pass runs at the first hold's deadline. Its pending input's target is not known yet: the
    /// pass counts as `boundExpired`, never against an earlier input's target.
    @Test func aPassWaitsAtMostOneRefreshInARow() {
        let rig = Rig()
        // An earlier click in a Chromium page: its pass ran with nothing pending.
        rig.pump.scheduleNow()
        rig.dispatches.end(.chromiumPage)
        rig.timer.fire()
        #expect(rig.passes == 2)
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 2)
        rig.clock.advance(by: .milliseconds(5))
        rig.dispatches.end(.terminal) // the next key is already queued
        rig.timer.fire()
        #expect(rig.passes == 2, "still within the refresh")
        #expect(rig.timer.armed.map { abs($0 - (Self.refresh - 0.005)) < 1e-9 } == true, "the first hold's deadline, not a new one")
        rig.clock.advance(by: .nanoseconds(Int64(Self.refresh * 1e9) - 5_000_000))
        rig.timer.fire()
        #expect(rig.passes == 3, "one refresh in a row at most")
        #expect(rig.pump.stats.passesWhileInputPending.boundExpired == 1)
        #expect(rig.pump.stats.passesWhileInputPending[.chromiumPage] == 0, "an earlier Chromium click does not hide it")
        #expect(rig.pump.stats.passesWhileInputPending[.other] == 0)
        #expect(rig.pump.stats.deferredForInput == 1, "one hold, however many fires it took")
        // The bound starts over after a pass.
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 3)
        #expect(rig.pump.stats.deferredForInput == 2)
        #expect(rig.timer.armed.map { abs($0 - Self.refresh) < 1e-9 } == true)
    }

    /// A hold that starts just before the frame deadline ends at it: the pass due before the deadline
    /// does not slip a whole refresh past it.
    @Test func aHoldEndsByTheNextFrameDeadline() {
        let rig = Rig()
        rig.frameTarget = rig.clock.seconds + 0.001
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 1)
        #expect(rig.timer.armed.map { abs($0 - 0.001) < 1e-9 } == true, "the frame deadline, before the refresh bound")
        rig.clock.advance(by: .milliseconds(1))
        rig.timer.fire()
        #expect(rig.passes == 2, "the pass runs at the deadline")
        #expect(rig.pump.stats.passesWhileInputPending.boundExpired == 1)
    }

    /// The last tick's frame may be shown already: the hold ends at the next one, a refresh later.
    @Test func aShownFrameTargetBoundsTheHoldByTheNextFrame() {
        let rig = Rig()
        rig.frameTarget = rig.clock.seconds - 0.002
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.timer.armed.map { abs($0 - (Self.refresh - 0.002)) < 1e-9 } == true)
    }

    @Test func inputToAChromiumPageRunsOnePassOnTheNextRunLoopPass() {
        let rig = Rig()
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 1)
        // The wheel event reaches the page; Chromium asks for work to route and ack it.
        rig.pump.request(milliseconds: 0)
        rig.dispatches.end(.chromiumPage)
        #expect(rig.passes == 1, "never inside the input's dispatch")
        #expect(rig.timer.armed == 0)
        #expect(rig.timer.tolerance == 0)
        rig.timer.fire()
        #expect(rig.passes == 2, "the next wheel is already queued: the pass runs anyway")
        #expect(rig.pump.stats.passesWhileInputPending[.chromiumPage] == 1)
        #expect(rig.pump.stats.passesWhileInputPending.boundExpired == 0)
        // The next due pass waits for input again.
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 2)
        #expect(rig.pump.stats.deferredForInput == 2)
    }

    @Test func aChromiumDispatchWithNoDueWorkRunsNoPass() {
        let rig = Rig()
        rig.pump.request(milliseconds: 50)
        rig.dispatches.end(.chromiumPage)
        #expect(rig.passes == 1, "only the start's pass: CEF's delayed task is not due")
        #expect(rig.timer.armed.map { abs($0 - 0.05) < 1e-9 } == true)
    }

    /// A hold that ends with no pass (CEF moved its request later) leaves no bound behind: the next
    /// hold, tens of milliseconds later, waits its own refresh instead of running at once.
    @Test func aHoldCEFMovedPastLeavesNoStaleBound() {
        let rig = Rig()
        rig.pump.request(milliseconds: 5)
        rig.clock.advance(by: .milliseconds(5))
        rig.pending.isPending = true
        rig.timer.fire()
        #expect(rig.passes == 1)
        #expect(rig.pump.stats.deferredForInput == 1)
        rig.pump.request(milliseconds: 50)
        rig.clock.advance(by: .milliseconds(50))
        rig.timer.fire()
        #expect(rig.passes == 1, "still pending: a new hold, not a pass ahead of the key")
        #expect(rig.pump.stats.deferredForInput == 2)
        #expect(rig.pump.stats.passesWhileInputPending.boundExpired == 0)
        #expect(rig.timer.armed.map { abs($0 - Self.refresh) < 1e-9 } == true)
    }

    /// A dispatch that ends inside a pass (a nested run loop: a menu, a modal panel) runs nothing;
    /// the outer pass re-arms when it returns, as the reentrancy rule says.
    @Test func aDispatchInsideAPassDoesNotReenterThePump() {
        let rig = Rig()
        var depth = 0
        var maxDepth = 0
        rig.onWork = {
            depth += 1
            maxDepth = max(maxDepth, depth)
            rig.pump.scheduleNow()
            rig.dispatches.end(.chromiumPage)
            depth -= 1
        }
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(maxDepth == 1)
        #expect(rig.passes == 2)
        #expect(rig.timer.armed == 0, "the request made inside the pass runs on the next run loop pass")
    }

    @Test func stopEndsTheDispatchSubscription() {
        let rig = Rig()
        rig.pump.stop()
        #expect(rig.dispatches.isCancelled)
        rig.pump.request(milliseconds: 0)
        rig.dispatches.end(.chromiumPage)
        #expect(rig.passes == 1)
    }

    /// Without a policy (the feature off) pending input changes nothing.
    @Test func withoutAPolicyInputHoldsNothing() {
        let clock = ManualClock()
        let timer = Timer()
        var passes = 0
        let pump = CEFMessagePump(work: { passes += 1 }, timer: timer, clock: { clock.seconds },
                                  ledger: WakeupLedger())
        pump.start()
        timer.fire()
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 2)
        #expect(pump.stats.passTimes.count == 0)
        pump.stop()
    }

    /// A pass input holds takes no late frame's slice: once the input's dispatch ends, the late
    /// frame's one pass still runs.
    @Test func aHeldPassLeavesTheLateFrameItsSlice() {
        let media = CEFMessagePumpStarvationTests.Media()
        let window = FrameScheduler.testing(mediaTime: media.read) { _ in CEFMessagePumpStarvationTests.Link() }
        let starvation = RenderStarvationGuard(holdsWork: true, visibility: CEFMessagePumpStarvationTests.Shown(),
                                               mediaTime: media.read)
        starvation.watch(window)
        let spring = FrameClient(owner: "spring", on: window) { _ in true }
        let timer = Timer()
        let pending = Pending()
        let dispatches = Dispatches()
        var passes = 0
        let pump = CEFMessagePump(work: { passes += 1 }, timer: timer, clock: { media.now },
                                  ledger: WakeupLedger(), starvation: starvation)
        pump.setInputPolicy(CEFPumpInputPolicy(pending: pending, dispatches: dispatches, refreshInterval: { Self.refresh }))
        pump.start()
        timer.fire()
        #expect(passes == 1)
        spring.activate()
        window.frameDidFire(timestamp: media.now, refreshInterval: 1.0 / 60)
        media.now += 0.2
        pending.isPending = true
        pump.scheduleNow()
        timer.fire()
        #expect(passes == 1, "held for the key")
        media.now += 0.002
        pending.isPending = false
        dispatches.end(.terminal)
        timer.fire()
        #expect(passes == 2, "the late frame's one pass, after the key")
        #expect(pump.stats.lateFrameHolds == 0)
        #expect(pump.stats.deferredForInput == 1)
        spring.deactivate()
        pump.stop()
    }

    // MARK: The app's dispatch ends (InputEventTap)

    /// Real events through an input tap: AppKit's delivery to a page window is a Chromium page, a
    /// plain window or an event cmux consumed is not, and pointer moves are not followed.
    @Test func theTapClassifiesByDeliveredWindow() throws {
        let windows = try Windows()
        defer { windows.close() }
        let tap = InputEventTap()
        let dispatches = CEFPumpTapDispatches(tap: tap, pageWindowClass: { windows.pageClass })
        var targets: [InputTarget] = []
        let subscription = dispatches.observeDispatchEnd { targets.append($0) }
        #expect(tap.subscriberCount(.key, stage: .dispatchEnd) == 1)
        #expect(tap.subscriberCount(.pointerMove, stage: .dispatchEnd) == 0)

        tap.deliverDispatchEnd(try Windows.key(in: windows.page), outcome: .delivered)
        tap.deliverDispatchEnd(try Windows.mouse(.leftMouseDown, in: windows.page), outcome: .delivered)
        tap.deliverDispatchEnd(try Windows.key(in: windows.plain), outcome: .delivered)
        tap.deliverDispatchEnd(try Windows.key(in: windows.page), outcome: .consumed)
        tap.deliverDispatchEnd(try Windows.mouse(.mouseMoved, in: windows.page), outcome: .delivered)
        #expect(targets == [.chromiumPage, .chromiumPage, .other, .other])
        withExtendedLifetime(dispatches) {}
        subscription.cancel()
        #expect(tap.subscriberCount(.key, stage: .dispatchEnd) == 0)
    }

    /// A key a cmux shortcut consumed in a page window ends the hold (the key router's path emits a
    /// dispatch end too) and runs no Chromium pass while input is pending; a key the page got does.
    @Test func aConsumedKeyInAPageWindowEndsTheHoldWithoutAChromiumPass() throws {
        let windows = try Windows()
        defer { windows.close() }
        let tap = InputEventTap()
        let rig = Rig(dispatches: CEFPumpTapDispatches(tap: tap, pageWindowClass: { windows.pageClass }))
        rig.pending.isPending = true
        rig.pump.scheduleNow()
        rig.timer.fire()
        #expect(rig.passes == 1)
        tap.deliverDispatchEnd(try Windows.key(in: windows.page), outcome: .consumed)
        #expect(rig.timer.armed == 0, "the hold ends with the consumed key's dispatch")
        rig.timer.fire()
        #expect(rig.passes == 1, "more input is pending and the key never reached Chromium: held again")
        #expect(rig.pump.stats.passesWhileInputPending[.chromiumPage] == 0)
        tap.deliverDispatchEnd(try Windows.key(in: windows.page), outcome: .delivered)
        rig.timer.fire()
        #expect(rig.passes == 2)
        #expect(rig.pump.stats.passesWhileInputPending[.chromiumPage] == 1)
    }

    // MARK: Doubles

    @MainActor
    final class Rig {
        let clock = ManualClock()
        let timer = Timer()
        let pending = Pending()
        let dispatches = Dispatches()
        var frameTarget: TimeInterval?
        var passes = 0
        var onWork: () -> Void = {}
        private(set) var pump: CEFMessagePump!

        init(dispatches source: (any CEFPumpInputDispatches)? = nil) {
            let clock = clock
            pump = CEFMessagePump(work: { [unowned self] in
                self.passes += 1
                self.onWork()
            }, timer: timer, clock: { clock.seconds }, ledger: WakeupLedger())
            pump.setInputPolicy(CEFPumpInputPolicy(pending: pending, dispatches: source ?? dispatches,
                                                   refreshInterval: { CEFPumpInputYieldTests.refresh },
                                                   frameTarget: { [unowned self] in self.frameTarget }))
            pump.start()
            timer.fire()
        }
    }

    final class Pending: InputPendingSource {
        var isPending = false
        func hasPendingInput(uptime: TimeInterval) -> Bool { isPending }
    }

    final class Dispatches: CEFPumpInputDispatches {
        private var handler: ((InputTarget) -> Void)?
        private var subscription: InputSubscription?

        var isCancelled: Bool { subscription?.isCancelled ?? true }

        func observeDispatchEnd(_ handler: @escaping (InputTarget) -> Void) -> InputSubscription {
            self.handler = handler
            let subscription = InputSubscription(flag: InputSubscriptionFlag())
            self.subscription = subscription
            return subscription
        }

        func end(_ target: InputTarget) {
            guard !isCancelled else { return }
            handler?(target)
        }
    }

    /// A page window (a fresh subclass standing in for `CefNSWindow`) and a plain window, on screen
    /// so their events find them.
    @MainActor
    final class Windows {
        let pageClass: AnyClass
        let page: NSWindow
        let plain: NSWindow

        init() throws {
            _ = NSApplication.shared // events find their window through the application object
            let cls = try #require(objc_allocateClassPair(NSWindow.self, "CmuxTestPumpCefNSWindow_\(UInt32.random(in: 0 ... .max))", 0))
            objc_registerClassPair(cls)
            pageClass = cls
            page = Self.window(of: try #require(cls as? NSWindow.Type))
            plain = Self.window(of: NSWindow.self)
        }

        func close() {
            for window in [page, plain] { window.orderOut(nil) }
        }

        private static func window(of type: NSWindow.Type) -> NSWindow {
            let window = type.init(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                   backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            return window
        }

        static func key(in window: NSWindow) throws -> NSEvent {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                      isARepeat: false, keyCode: 0))
            try #require(event.window === window)
            return event
        }

        static func mouse(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
            let event = try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: 20), modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            try #require(event.window === window)
            return event
        }
    }

    /// The pump's timer, fired by hand.
    final class Timer: CEFPumpTimer {
        var onFire: (() -> Void)?
        var armed: TimeInterval?
        var tolerance: TimeInterval?
        func arm(after delay: TimeInterval, tolerance: TimeInterval) {
            armed = delay
            self.tolerance = tolerance
        }
        func disarm() { armed = nil }
        func invalidate() { armed = nil }
        func fire() {
            armed = nil
            onFire?()
        }
    }
}

private extension ManualClock {
    /// The clock's time in seconds, the pump's clock unit.
    nonisolated var seconds: TimeInterval {
        let offset = now.offset.components
        return 100 + TimeInterval(offset.seconds) + TimeInterval(offset.attoseconds) / 1e18
    }
}
