import AppKit
import CmuxNextCompat
@testable import CmuxNextInput
import CmuxNextInputCore
import Darwin
import Testing

/// The app's one input tap: a subscription hears only its classes and its window,
/// intercepts run in their declared order, a consuming intercept stops later intercepts but not
/// observers, cancelled and released subscriptions stop at once, the tap keeps the last dispatched
/// and last pointer records, and a dispatch allocates nothing.
@MainActor @Suite(.serialized)
struct InputEventTapTests {
    /// What handlers saw: a class, so `@MainActor` handlers share it without capturing a local `var`.
    final class Log {
        var calls: [String] = []
        var windows: [Int] = []
        var records: [InputEventRecord] = []
        var count = 0
        var open = false
        var late: InputSubscription?
        var own: InputSubscription?
    }

    // MARK: classes and windows

    @Test func aSubscriberHearsOnlyItsClasses() throws {
        let tap = InputEventTap()
        let log = Log()
        let keySubscription = tap.subscribe(class: .key) { _ in log.calls.append("key") }
        let buttonSubscription = tap.subscribe(class: .button, phase: .afterDispatch) { _ in log.calls.append("button") }

        try Self.dispatch(Self.key(), through: tap)
        try Self.dispatch(Self.mouse(.leftMouseDown), through: tap)
        try Self.dispatch(Self.mouse(.mouseMoved), through: tap)
        try Self.dispatch(Self.scroll(), through: tap)

        #expect(log.calls == ["key", "button"], "each subscriber hears its own class only")
        #expect(tap.subscriberCount(.key, stage: .observe) == 1)
        #expect(tap.subscriberCount(.button, stage: .afterDispatch) == 1)
        #expect(tap.subscriberCount(.scroll, stage: .observe) == 0)
        withExtendedLifetime((keySubscription, buttonSubscription)) {}
    }

    @Test func aWindowScopedSubscriberHearsItsWindowAndItsChildWindowsOnly() throws {
        _ = NSApplication.shared
        let mine = Self.window()
        let other = Self.window()
        let child = Self.window()
        mine.addChildWindow(child, ordered: .above)
        defer {
            mine.removeChildWindow(child)
            for window in [mine, other, child] { window.orderOut(nil) }
        }
        let tap = InputEventTap()
        let heard = Log()
        let intercepted = Log()
        let subscription = tap.subscribe(class: .button, window: .window(mine)) { event in heard.windows.append(event.windowNumber) }
        let intercept = tap.subscribe(class: .button, phase: .intercept(order: .standard), window: .window(mine)) { event in
            intercepted.windows.append(event.windowNumber)
            return .pass
        }

        try Self.dispatch(Self.mouse(.leftMouseDown, in: other), through: tap)
        try Self.dispatch(Self.mouse(.leftMouseDown), through: tap)
        try Self.dispatch(Self.mouse(.leftMouseDown, in: mine), through: tap)
        try Self.dispatch(Self.mouse(.leftMouseDown, in: child), through: tap)

        #expect(heard.windows == [mine.windowNumber, child.windowNumber], "another window's and a windowless event are not heard")
        #expect(intercepted.windows == heard.windows, "intercepts are scoped the same way")
        withExtendedLifetime((subscription, intercept)) {}
    }

    @Test func aCoreObserverFiltersByWindowNumberAndGetsRecords() throws {
        _ = NSApplication.shared
        let mine = Self.window()
        let other = Self.window()
        defer { for window in [mine, other] { window.orderOut(nil) } }
        let tap = InputEventTap()
        let observing: any InputObserving = tap
        let log = Log()
        let scoped = observing.observe([.button], windowNumber: mine.windowNumber) { record in log.records.append(record) }
        let unscoped = observing.observe(.button) { _ in log.count += 1 }

        try Self.dispatch(Self.mouse(.leftMouseDown, in: other), through: tap)
        try Self.dispatch(Self.mouse(.leftMouseDown, at: CGPoint(x: 12, y: 34), in: mine, clickCount: 2), through: tap)

        #expect(log.count == 2)
        #expect(log.records.count == 1, "the other window's click is not heard")
        let record = try #require(log.records.first)
        #expect(record.type == .leftMouseDown)
        #expect(record.windowNumber == mine.windowNumber)
        #expect(record.ownerWindowNumber == mine.windowNumber)
        #expect(record.location == InputPoint(x: 12, y: 34))
        #expect(record.clickCount == 2)
        #expect(record.keyCode == 0, "a field the type does not have is zero")
        withExtendedLifetime((scoped, unscoped)) {}
    }

    // MARK: intercepts

    @Test func interceptsRunInTheirDeclaredOrder() throws {
        let tap = InputEventTap()
        let log = Log()
        let standard = tap.subscribe(class: .key, phase: .intercept(order: .standard)) { _ in log.calls.append("standard"); return .pass }
        let layout = tap.subscribe(class: .key, phase: .intercept(order: .layout)) { _ in log.calls.append("layout"); return .pass }
        let popupA = tap.subscribe(class: .key, phase: .intercept(order: .popup)) { _ in log.calls.append("popupA"); return .pass }
        let modal = tap.subscribe(class: .key, phase: .intercept(order: .modal)) { _ in log.calls.append("modal"); return .pass }
        let popupB = tap.subscribe(class: .key, phase: .intercept(order: .popup)) { _ in log.calls.append("popupB"); return .pass }

        let result = tap.deliverIntercepts(try Self.key())

        #expect(result == .pass)
        #expect(log.calls == ["modal", "popupA", "popupB", "layout", "standard"], "lower order first; equal orders in subscription order")
        withExtendedLifetime((standard, layout, popupA, modal, popupB)) {}
    }

    @Test func aConsumingInterceptStopsLaterInterceptsButNotObservers() throws {
        let tap = InputEventTap()
        let log = Log()
        let observer = tap.subscribe(class: .key) { _ in log.calls.append("observe") }
        let first = tap.subscribe(class: .key, phase: .intercept(order: .modal)) { _ in log.calls.append("modal"); return .consume }
        let later = tap.subscribe(class: .key, phase: .intercept(order: .standard)) { _ in log.calls.append("standard"); return .pass }
        let after = tap.subscribe(class: .key, phase: .afterDispatch) { _ in log.calls.append("after") }

        let consumed = try Self.dispatch(Self.key(), through: tap)

        #expect(consumed, "the event does not reach AppKit")
        #expect(log.calls == ["observe", "modal", "after"], "observers had it; the later intercept did not; after-dispatch still does")
        withExtendedLifetime((observer, first, later, after)) {}
    }

    // MARK: dispatch end

    /// The dispatch end hears its classes once per event with how the dispatch ended, outside the
    /// dispatch scope: a subscription made in it is live at once for the next event.
    @Test func theDispatchEndHearsItsClassesWithTheOutcome() throws {
        let tap = InputEventTap()
        let log = Log()
        let subscription = tap.observeDispatchEnd([.key, .button]) { event, outcome in
            log.calls.append("\(event.type == .keyDown ? "key" : "button").\(outcome == .delivered ? "delivered" : "consumed")")
            if log.late == nil { log.late = tap.observeDispatchEnd(.key) { _, _ in log.count += 1 } }
        }
        #expect(tap.subscriberCount(.key, stage: .dispatchEnd) == 1)
        #expect(tap.subscriberCount(.key, stage: .afterDispatch) == 0)

        let key = try Self.key()
        Self.dispatch(key, through: tap)
        #expect(log.calls.isEmpty, "the three stages do not deliver it")
        tap.deliverDispatchEnd(key, outcome: .consumed)
        tap.deliverDispatchEnd(try Self.mouse(.leftMouseDown), outcome: .delivered)
        tap.deliverDispatchEnd(try Self.mouse(.mouseMoved), outcome: .delivered)
        #expect(log.calls == ["key.consumed", "button.delivered"])
        #expect(log.count == 0, "a subscription made in a delivery never hears that event")
        tap.deliverDispatchEnd(key, outcome: .delivered)
        #expect(log.count == 1)
        subscription.cancel()
        tap.deliverDispatchEnd(key, outcome: .delivered)
        #expect(log.calls.count == 3)
        #expect(tap.subscriberCount(.button, stage: .dispatchEnd) == 0)
        withExtendedLifetime(subscription) {}
    }

    // MARK: lifetime

    @Test func aCancelledOrReleasedSubscriptionStopsAtOnce() throws {
        let tap = InputEventTap()
        let log = Log()
        let keep = tap.subscribe(class: .key) { _ in log.calls.append("kept") }
        let cancel = tap.subscribe(class: .key) { _ in log.calls.append("cancelled") }
        var release: InputSubscription? = tap.subscribe(class: .key, phase: .intercept(order: .standard)) { _ in log.calls.append("released"); return .pass }

        try Self.dispatch(Self.key(), through: tap)
        cancel.cancel()
        release = nil
        try Self.dispatch(Self.key(), through: tap)

        #expect(log.calls == ["kept", "cancelled", "released", "kept"])
        #expect(release == nil)
        #expect(tap.subscriberCount(.key, stage: .observe) == 1)
        #expect(tap.subscriberCount(.key, stage: .intercept) == 0, "the count returns to base on every end path")
        withExtendedLifetime(keep) {}
    }

    @Test func aSubscriptionMadeOrCancelledInAHandlerTakesEffectFromTheNextEvent() throws {
        let tap = InputEventTap()
        let log = Log()
        let starter = tap.subscribe(class: .key) { _ in
            if log.late == nil { log.late = tap.subscribe(class: .key) { _ in log.calls.append("late") } }
        }
        log.own = tap.subscribe(class: .key) { _ in
            log.calls.append("own")
            log.own?.cancel()
        }

        try Self.dispatch(Self.key(), through: tap)
        #expect(log.calls == ["own"], "a subscription made during a delivery hears the next event")
        try Self.dispatch(Self.key(), through: tap)

        #expect(log.calls == ["own", "late"], "a handler that cancelled itself is not called again")
        #expect(tap.subscriberCount(.key, stage: .observe) == 2)
        withExtendedLifetime(starter) {}
    }

    /// An observer that starts a drag on mouse-down and subscribes the drag's after-dispatch button
    /// handler (for the mouse-up) must not hear the mouse-down that started it.
    @Test func aSubscriptionMadeInOneStageDoesNotHearTheSameEventInALaterStage() throws {
        let tap = InputEventTap()
        let log = Log()
        let starter = tap.subscribe(class: .button) { event in
            guard event.type == .leftMouseDown, log.late == nil else { return }
            log.late = tap.subscribe(class: .button, phase: .afterDispatch) { event in log.calls.append("after \(event.type.rawValue)") }
            log.own = tap.subscribe(class: .button, phase: .intercept(order: .dragSession)) { _ in
                log.calls.append("intercept")
                return .consume
            }
        }

        let down = try Self.mouse(.leftMouseDown)
        #expect(!Self.dispatch(down, through: tap), "the intercept made during this event's observe stage did not run")
        #expect(log.calls.isEmpty, "neither later stage of the same event called the new subscriptions")
        #expect(tap.subscriberCount(.button, stage: .afterDispatch) == 1)

        let up = try Self.mouse(.leftMouseUp)
        #expect(Self.dispatch(up, through: tap))
        #expect(log.calls == ["intercept", "after \(up.type.rawValue)"], "the next event reaches both")
        withExtendedLifetime(starter) {}
    }

    // MARK: presses

    /// The no-activate guard's signal: a person's key-down or mouse-down, gated per event by `while`.
    @Test func aPressSubscriberHearsOnlyKeyAndMouseDownsWhileActive() throws {
        let tap = InputEventTap()
        let log = Log()
        let subscription = tap.subscribePresses([.keyDown, .mouseDown], while: { !log.open }) { _ in log.count += 1 }

        for event in [try Self.key(), try Self.key(type: .keyUp), try Self.key(type: .flagsChanged),
                      try Self.mouse(.rightMouseDown), try Self.mouse(.rightMouseUp), try Self.mouse(.leftMouseDragged),
                      try Self.scroll()] {
            Self.dispatch(event, through: tap)
        }
        #expect(log.count == 2, "a key-down and a mouse-down; ups, flags, drags and scrolls are not presses")

        log.open = true  // the app's own synthetic input is dispatching
        try Self.dispatch(Self.key(), through: tap)
        try Self.dispatch(Self.mouse(.leftMouseDown), through: tap)
        #expect(log.count == 2)
        #expect(tap.subscriberCount(.scroll, stage: .observe) == 0, "only the press classes are subscribed")
        withExtendedLifetime(subscription) {}
    }

    /// The click work after dispatch runs for every mouse-down, also one an intercept consumed.
    @Test func anAfterDispatchMouseDownSubscriberHearsConsumedDowns() throws {
        let tap = InputEventTap()
        let log = Log()
        let clicks = tap.subscribePresses(.mouseDown, phase: .afterDispatch) { event in log.calls.append("\(event.type.rawValue)") }
        let modal = tap.subscribe(class: .button, phase: .intercept(order: .modal)) { event in
            event.type == .otherMouseDown ? .consume : .pass
        }

        let types: [NSEvent.EventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .otherMouseUp]
        for type in types { try Self.dispatch(Self.mouse(type), through: tap) }

        #expect(log.calls == [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown].map { "\($0.rawValue)" },
                "ups are not clicks; the consumed down still counts")
        #expect(tap.subscriberCount(.key, stage: .afterDispatch) == 0)
        withExtendedLifetime((clicks, modal)) {}
    }

    @Test func theWhilePredicateGatesEachCall() throws {
        let tap = InputEventTap()
        let log = Log()
        let subscription = tap.subscribe(class: .key, phase: .intercept(order: .popup), while: { log.open }) { _ in log.count += 1; return .consume }

        #expect(try !Self.dispatch(Self.key(), through: tap), "inactive: the event passes")
        log.open = true
        #expect(try Self.dispatch(Self.key(), through: tap))
        #expect(log.count == 1)
        withExtendedLifetime(subscription) {}
    }

    // MARK: records and flags

    @Test func theTapKeepsTheLastDispatchedAndTheLastPointerEvent() throws {
        let tap = InputEventTap()
        #expect(tap.lastDispatched == nil)
        #expect(tap.lastPointer == nil)

        try Self.dispatch(Self.mouse(.leftMouseDragged, at: CGPoint(x: 5, y: 6)), through: tap)
        try Self.dispatch(Self.key(keyCode: 36, modifiers: [.command, .shift]), through: tap)

        let last = try #require(tap.lastDispatched)
        #expect(last.type == .keyDown)
        #expect(last.keyCode == 36)
        #expect(last.modifierFlags == [.command, .shift])
        let pointer = try #require(tap.lastPointer)
        #expect(pointer.type == .leftMouseDragged, "a key does not replace the last pointer event")
        #expect(pointer.location == InputPoint(x: 5, y: 6))
    }

    /// Tracking-area edges reach only a subscriber that names `.tracking` (no `.all` or `.pointer`
    /// one), and, made by a move rather than input of their own, replace neither last event.
    @Test func trackingAreaEdgesReachOnlyTheirSubscribersAndAreNoLastEvent() throws {
        let tap = InputEventTap()
        let log = Log()
        let tracking = tap.subscribe(class: .tracking) { log.calls.append($0.type == .mouseEntered ? "enter" : "exit") }
        let pointer = tap.subscribe(class: .pointer) { _ in log.calls.append("pointer") }
        try Self.dispatch(Self.mouse(.mouseMoved, at: CGPoint(x: 1, y: 2)), through: tap)
        _ = NSApplication.shared
        for type in [NSEvent.EventType.mouseEntered, .mouseExited] {
            let edge = try #require(NSEvent.enterExitEvent(with: type, location: CGPoint(x: 9, y: 9), modifierFlags: [], timestamp: 2,
                                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            Self.dispatch(edge, through: tap)
        }
        #expect(log.calls == ["pointer", "enter", "exit"])
        #expect(tap.lastDispatched?.type == .mouseMoved, "a tracking-area edge replaced the last dispatched event")
        #expect(tap.lastPointer?.type == .mouseMoved, "a tracking-area edge replaced the last pointer event")
        withExtendedLifetime((tracking, pointer)) {}
    }

    @Test func ownersSetAndClearFlags() {
        let tap = InputEventTap()
        tap.setFlag(.hintsShowing, true)
        tap.setFlag(.findPillOpen, true)
        tap.setFlag(.hintsShowing, false)
        #expect(tap.flags == [.findPillOpen])
    }

    /// A flag several owners hold (a find pill per window) stays set until the last releases it; a
    /// release with no hold changes nothing.
    @Test func aHeldFlagClearsWhenTheLastHolderReleasesIt() {
        let tap = InputEventTap()
        tap.releaseFlag(.findPillOpen)
        #expect(tap.flags.isEmpty)
        tap.holdFlag(.findPillOpen)
        tap.holdFlag(.findPillOpen)
        tap.releaseFlag(.findPillOpen)
        #expect(tap.flags == [.findPillOpen], "one holder is left")
        tap.releaseFlag(.findPillOpen)
        #expect(tap.flags.isEmpty)
        tap.releaseFlag(.findPillOpen)
        tap.holdFlag(.findPillOpen)
        #expect(tap.flags == [.findPillOpen], "an extra release took a later hold")
    }

    @Test func aReleasedGlobalObserverIsRemoved() throws {
        let tap = InputEventTap()
        var subscription: InputSubscription? = tap.globalObserve([.leftMouseDown]) { _ in }
        #expect(tap.globalMonitorCount == 1)
        subscription = nil
        try Self.dispatch(Self.key(), through: tap)
        #expect(tap.globalMonitorCount == 0, "the next delivery removes the AppKit monitor")
        #expect(subscription == nil)
    }

    // MARK: cost

    /// Delivering through every stage to live subscribers, window-scoped ones included, allocates
    /// nothing per event, compared with the same loop that does not deliver (the Debug loop allocates
    /// by itself).
    @Test func aDispatchAllocatesNothing() throws {
        _ = NSApplication.shared
        let mine = Self.window()
        let other = Self.window()
        defer { for window in [mine, other] { window.orderOut(nil) } }
        let tap = InputEventTap()
        let log = Log()
        let subscriptions = [
            tap.subscribe(class: .all) { _ in log.count += 1 },
            tap.observe(.all, windowNumber: nil) { _ in log.count += 1 },
            tap.subscribe(class: .all, phase: .intercept(order: .standard), while: { log.count >= 0 }) { _ in log.count += 1; return .pass },
            tap.subscribe(class: .all, phase: .afterDispatch) { _ in log.count += 1 },
            // Scoped: one hears `mine`'s events, the other never matches and looks up the owner window.
            tap.subscribe(class: .all, window: .window(mine)) { _ in log.count += 1 },
            tap.observe(.all, windowNumber: other.windowNumber) { _ in log.count += 1 },
            tap.subscribe(class: .all, phase: .intercept(order: .layout), window: .window(other)) { _ in log.count += 1; return .pass },
            tap.subscribe(class: .all, phase: .afterDispatch, window: .window(mine)) { _ in log.count += 1 },
        ]
        let events = [try Self.key(), try Self.mouse(.leftMouseDown), try Self.mouse(.mouseMoved), try Self.scroll(),
                      try Self.mouse(.leftMouseDown, in: mine), try Self.mouse(.leftMouseDragged, in: mine)]
        for event in events { Self.dispatch(event, through: tap) }
        var sink = 0
        func allocations(delivering: Bool) -> Int? {
            MallocProbe.allocations {
                for _ in 0..<1_000 {
                    for event in events {
                        if delivering {
                            Self.dispatch(event, through: tap)
                        } else {
                            sink &+= Int(event.type.rawValue)
                        }
                    }
                }
            }
        }

        let control = MallocProbe.allocations { sink &+= ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        let baseline = try #require(allocations(delivering: false))
        let delivered = allocations(delivering: true)

        #expect(delivered == baseline, "the loop alone made \(baseline)")
        #expect(log.count > 26_000, "the scoped subscribers heard `mine`'s events too")
        withExtendedLifetime(subscriptions) {}
    }

    // MARK: helpers

    /// Runs `event` through the tap as `CmuxApplication.sendEvent` does (one dispatch scope around the
    /// three stages); true when an intercept consumed it.
    @discardableResult
    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) -> Bool {
        var consumed = false
        tap.dispatching {
            tap.deliverObserve(event)
            consumed = tap.deliverIntercepts(event) == .consume
            tap.deliverAfterDispatch(event)
        }
        return consumed
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func key(type: NSEvent.EventType = .keyDown, keyCode: UInt16 = 0,
                            modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                             windowNumber: 0, context: nil, characters: "a",
                                             charactersIgnoringModifiers: "a", isARepeat: false, keyCode: keyCode))
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint = .zero, in window: NSWindow? = nil,
                              clickCount: Int = 1) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                               windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                               clickCount: clickCount, pressure: 1))
    }

    private static func scroll() throws -> NSEvent {
        _ = NSApplication.shared
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -3, wheel2: 0, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }
}

/// Counts the allocations one thread makes, through libmalloc's `malloc_logger` hook (the one malloc
/// stack logging uses), as FeatureListTests does.
private nonisolated struct MallocProbe {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// `MALLOC_LOG_TYPE_ALLOCATE` (libmalloc stack_logging.h).
    static let allocateType: UInt32 = 2
    static let count = Atomic<Int>(0)
    static let thread = Atomic<UInt64>(0)

    /// The allocations `body` makes on this thread, or nil when the hook is missing.
    static func allocations(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        var id: UInt64 = 0
        pthread_threadid_np(nil, &id)
        count.store(0, ordering: .relaxed)
        thread.store(id, ordering: .relaxed)
        let previous = slot.pointee
        slot.pointee = { type, _, _, _, _, _ in
            guard type & MallocProbe.allocateType != 0 else { return }
            var id: UInt64 = 0
            pthread_threadid_np(nil, &id)
            if id == MallocProbe.thread.load(ordering: .relaxed) { _ = MallocProbe.count.wrappingAdd(1, ordering: .relaxed) }
        }
        body()
        slot.pointee = previous
        thread.store(0, ordering: .relaxed)
        return count.load(ordering: .relaxed)
    }
}
