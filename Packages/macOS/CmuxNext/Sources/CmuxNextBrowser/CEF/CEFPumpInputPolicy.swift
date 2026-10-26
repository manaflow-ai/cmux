import AppKit
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups
import Foundation

/// The person's input before the in-process CEF pump (plans/cmux-next/chrome-parity/p04-input.md,
/// task 024). `CefDoMessageLoopWork` runs on the main thread, so a pass that starts while a key, a
/// click, a scroll begin or a drag waits in the event queue delays that input by the whole pass.
///
/// Chrome's main-thread scheduler runs input first and bounds how long it lets other work wait
/// (`third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc`: input
/// priority, with the rendering-starvation bound). The policy does the same for the pump:
/// - input is pending: the pass waits until that input's dispatch ends, and at most one refresh
///   interval in a row (the frame deadline is the fallback when the input never reaches this app);
/// - after an input dispatched to a Chromium page, the pass CEF asked for runs at once, inside the
///   dispatch's after phase, not on a later run loop pass: Chromium's browser-side input pipeline
///   (`content/browser/renderer_host/input/input_router_impl.cc`, the wheel acks of
///   `components/input/mouse_wheel_event_queue.cc`) runs inside `CefDoMessageLoopWork`.
///
/// The policy owns no timer: the pump arms its own one timer at the hold's deadline. Slicing a pass
/// to the frame deadline is p03-rendering-116.
///
/// ```swift
/// pump.setInputPolicy(.app(tap: inputTap))  // CEFRuntime, feature cefPumpInputPolicy
/// // A test, with its own pending input and dispatches:
/// pump.setInputPolicy(CEFPumpInputPolicy(pending: pending, dispatches: dispatches, refreshInterval: { 1.0 / 120 }))
/// ```
final class CEFPumpInputPolicy {
    /// Where a dispatched input event went.
    nonisolated enum Target: Sendable, Equatable {
        /// A Chromium page in this process.
        case chromiumPage
        /// Anything else: a terminal, cmux's own views, a WebKit page.
        case other
    }

    /// What the pump does with a pass that is due.
    nonisolated enum Admission: Equatable, Sendable {
        /// No input is pending: run it.
        case run
        /// Input is pending and the pass has waited one refresh: run it, counted against `target`
        /// (the target of the last dispatched input, the stream the pending one continues).
        case runWhileInputPending(target: Target)
        /// Input is pending: hold the pass until its dispatch ends, or `deadline` at the latest.
        /// `began`: this hold starts the wait (a pass that waits across several inputs is one hold).
        case hold(deadline: TimeInterval, began: Bool)
    }

    private let pending: any InputPendingSource
    private let refreshInterval: () -> TimeInterval
    private var subscription: InputSubscription?
    /// When the pending input first held a pass since the last pass ran; nil when none is held.
    private var heldSince: TimeInterval?
    /// The target of the last input dispatched.
    private(set) var lastTarget = Target.other
    /// Called after each input dispatch ends with its target (the pump installs it at start).
    private var dispatchEnded: ((Target) -> Void)?

    /// - Parameters:
    ///   - pending: Whether a person's input waits for the main thread (`SessionInputPending`).
    ///   - dispatches: The end of each input's dispatch and where it went (``CEFPumpTapDispatches``).
    ///   - refreshInterval: The refresh interval of the display the person works on; the longest
    ///     a pass waits for input in a row.
    init(pending: any InputPendingSource, dispatches: any CEFPumpInputDispatches,
         refreshInterval: @escaping () -> TimeInterval) {
        self.pending = pending
        self.refreshInterval = refreshInterval
        subscription = dispatches.observeDispatchEnd { [weak self] target in self?.ended(target) }
    }

    /// The app's policy: `SessionInputPending` over the window server and `tap`, the dispatches of
    /// `tap` classified by window (``CEFPumpTapDispatches/pageWindowTarget()``), and the refresh
    /// interval of the display the person works on. Call once CEF's classes are loaded.
    static func app(tap: InputEventTap) -> CEFPumpInputPolicy {
        let events = WindowServerInputEvents(input: tap)
        return CEFPumpInputPolicy(pending: SessionInputPending(events: events),
                                  dispatches: CEFPumpTapDispatches(tap: tap, classify: CEFPumpTapDispatches.pageWindowTarget()),
                                  refreshInterval: { events.refreshInterval })
    }

    /// The longest a pass waits for input in a row: one refresh, 60 Hz when the display reports none.
    var holdBound: TimeInterval {
        let interval = refreshInterval()
        return interval.isFinite && interval > 0 ? interval : 1.0 / 60
    }

    /// `handler` runs after each input dispatch ends, with the input's target.
    func onDispatchEnd(_ handler: @escaping (Target) -> Void) {
        dispatchEnded = handler
    }

    /// Stops following dispatches (the pump stopped).
    func stop() {
        subscription?.cancel()
        subscription = nil
        dispatchEnded = nil
    }

    /// Whether the pass due at `now` (seconds since boot, the `NSEvent.timestamp` base) runs. Input
    /// still pending when its dispatch ended keeps the first hold's bound: a pass waits at most one
    /// refresh in a row, however many inputs follow.
    func admit(now: TimeInterval) -> Admission {
        guard pending.hasPendingInput(uptime: now) else {
            heldSince = nil
            return .run
        }
        let since = heldSince ?? now
        let deadline = since + holdBound
        // The timer and this clock differ by microseconds (CEFPumpSchedule.beginWork).
        guard now + 0.000_1 < deadline else {
            heldSince = nil
            return .runWhileInputPending(target: lastTarget)
        }
        let began = heldSince == nil
        heldSince = since
        return .hold(deadline: deadline, began: began)
    }

    /// The pass due right after an input dispatched to a Chromium page: it always runs (Chromium
    /// acks that input inside the pump), and the next hold starts its own bound.
    func admitAfterChromiumDispatch(now: TimeInterval) -> Admission {
        heldSince = nil
        return pending.hasPendingInput(uptime: now) ? .runWhileInputPending(target: .chromiumPage) : .run
    }

    private func ended(_ target: Target) {
        lastTarget = target
        dispatchEnded?(target)
    }
}

/// The end of each input's dispatch, with where it went: what ``CEFPumpInputPolicy`` follows.
/// ``CEFPumpTapDispatches`` is the app's; tests drive their own.
protocol CEFPumpInputDispatches: AnyObject {
    /// Calls `handler` after each key, mouse button, scroll and drag the app dispatched, until the
    /// returned subscription is cancelled or released.
    func observeDispatchEnd(_ handler: @escaping (CEFPumpInputPolicy.Target) -> Void) -> InputSubscription
}

/// ``CEFPumpInputDispatches`` from the app's one input tap: one after-dispatch subscription to the
/// input that counts as pending (`SessionInputPending.Kinds`). Pointer moves stream at the
/// pointer's rate and are not followed.
final class CEFPumpTapDispatches: CEFPumpInputDispatches {
    /// The classes whose dispatch ends a hold.
    static let followedClasses: InputEventClasses = [.key, .button, .scroll, .drag]

    private let tap: InputEventTap
    private let classify: (NSEvent) -> CEFPumpInputPolicy.Target

    /// - Parameters:
    ///   - tap: The app's one input tap.
    ///   - classify: Where a dispatched event went (the input target classifier, p04-input-005). It
    ///     runs for every followed event: O(1), no allocation.
    init(tap: InputEventTap, classify: @escaping (NSEvent) -> CEFPumpInputPolicy.Target) {
        self.tap = tap
        self.classify = classify
    }

    func observeDispatchEnd(_ handler: @escaping (CEFPumpInputPolicy.Target) -> Void) -> InputSubscription {
        tap.subscribe(class: Self.followedClasses, phase: .afterDispatch) { [classify] event in
            handler(classify(event))
        }
    }

    /// Where an event went by its window: a Chromium page window (`CefNSWindow`, a page or its
    /// DevTools; a key goes to it while it is key, a pointer event while it is under the pointer)
    /// or anything else. The class is looked up until CEF's framework has registered it, then kept.
    static func pageWindowTarget() -> (NSEvent) -> CEFPumpInputPolicy.Target {
        var pageClass: AnyClass?
        return { event in
            guard let window = event.window else { return .other }
            if pageClass == nil { pageClass = NSClassFromString("CefNSWindow") }
            guard let pageClass else { return .other }
            return window.isKind(of: pageClass) ? .chromiumPage : .other
        }
    }
}
