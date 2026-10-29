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
/// - input is pending: the pass waits until that input's dispatch ends, and at most until the next
///   frame deadline or one refresh interval in a row, whichever comes first;
/// - after an input AppKit delivered to a Chromium page, the pass CEF asked for runs on the next run
///   loop pass, even with more input queued: Chromium's browser-side input pipeline
///   (`content/browser/renderer_host/input/input_router_impl.cc`, the wheel acks of
///   `components/input/mouse_wheel_event_queue.cc`) runs inside `CefDoMessageLoopWork`.
///
/// The policy owns no timer: the pump arms its own one timer at the hold's deadline. Slicing a pass
/// to the frame deadline is p03-rendering-116.
///
/// ```swift
/// // CEFRuntime, feature cefPumpInputPolicy: the app's one pending source and frame clock.
/// pump.setInputPolicy(CEFPumpInputPolicy(pending: seams.pending, dispatches: CEFPumpTapDispatches(tap: input),
///                                        refreshInterval: seams.refreshInterval, frameTarget: seams.frameTarget))
/// ```
final class CEFPumpInputPolicy {
    /// What the pump does with a pass that is due.
    nonisolated enum Admission: Equatable, Sendable {
        /// No input is pending: run it.
        case run
        /// Input is pending, and the pass runs right after an input to `target` was dispatched
        /// (a Chromium page: it acks that input inside the pump).
        case runAfterDispatch(target: InputTarget)
        /// Input is still pending, and the pass has waited as long as it may.
        case runAtBound
        /// Only keys are pending and a Chromium page has the keyboard: they go to the page, whose
        /// input Chromium acks inside the pump, so the pass runs before them (counted under
        /// `chromiumPage` in ``CEFPumpStats/passesWhileInputPending``).
        case runForFocusedPage
        /// Input is pending: hold the pass until its dispatch ends, or `deadline` at the latest.
        /// `began`: this hold starts the wait (a pass that waits across several inputs is one hold).
        case hold(deadline: TimeInterval, began: Bool)
    }

    /// The timer and the pump's clock differ by microseconds (CEFPumpSchedule.beginWork).
    private static let slop: TimeInterval = 0.000_1

    private let pending: any InputPendingSource
    private let refreshInterval: @MainActor () -> TimeInterval
    private let frameTarget: @MainActor () -> TimeInterval?
    /// Kept for its subscription's life (its handler holds it weakly, so the tap holds no cycle).
    private let dispatches: any CEFPumpInputDispatches
    private var subscription: InputSubscription?
    /// The latest the held pass waits; nil when no pass is held.
    private var heldUntil: TimeInterval?
    /// Called after each input dispatch ends with its target (the pump installs it at start).
    private var dispatchEnded: ((InputTarget) -> Void)?

    /// - Parameters:
    ///   - pending: Whether a person's input waits for the main thread: the app's one source
    ///     (`MainFrameBudget.pendingInput`).
    ///   - dispatches: The end of each input's dispatch and where it went (``CEFPumpTapDispatches``).
    ///   - refreshInterval: The refresh interval of the frame clock; the longest a pass waits in a row.
    ///   - frameTarget: When the frame being made is shown (`FrameScheduler.frameTarget`), in the
    ///     pump's clock; nil while no frame is made. A held pass runs by the next one.
    init(pending: any InputPendingSource, dispatches: any CEFPumpInputDispatches,
         refreshInterval: @escaping @MainActor () -> TimeInterval,
         frameTarget: @escaping @MainActor () -> TimeInterval? = { nil }) {
        self.pending = pending
        self.refreshInterval = refreshInterval
        self.frameTarget = frameTarget
        self.dispatches = dispatches
        subscription = dispatches.observeDispatchEnd { [weak self] target in self?.dispatchEnded?(target) }
    }

    /// One refresh, 60 Hz when the frame clock reports none.
    var refresh: TimeInterval {
        let interval = refreshInterval()
        return interval.isFinite && interval > 0 ? interval : 1.0 / 60
    }

    /// `handler` runs after each input dispatch ends, with the input's target.
    func onDispatchEnd(_ handler: @escaping (InputTarget) -> Void) {
        dispatchEnded = handler
    }

    /// Stops following dispatches (the pump stopped).
    func stop() {
        subscription?.cancel()
        subscription = nil
        dispatchEnded = nil
        heldUntil = nil
    }

    /// Whether the pass due at `now` (seconds since boot, the `NSEvent.timestamp` base) runs. A hold
    /// keeps its first deadline until a pass runs or the hold ends (``holdEnded()``), however many
    /// inputs follow. `pageHasKeyboard`: a Chromium page is key, so pending keys go to it and hold
    /// nothing; pending pointer input goes to whatever view is under the pointer and still holds.
    func admit(now: TimeInterval, pageHasKeyboard: Bool = false) -> Admission {
        guard pending.hasPendingInput(uptime: now) else { return .run }
        if pageHasKeyboard, !pending.hasPendingPointerInput(uptime: now) { return .runForFocusedPage }
        if let heldUntil {
            return now + Self.slop < heldUntil ? .hold(deadline: heldUntil, began: false) : .runAtBound
        }
        let deadline = holdDeadline(from: now)
        heldUntil = deadline
        return .hold(deadline: deadline, began: true)
    }

    /// The pass due right after an input dispatched to `target` (a Chromium page): it runs whatever
    /// is pending, because Chromium acks that input inside the pump.
    func admitAfterDispatch(to target: InputTarget, now: TimeInterval) -> Admission {
        pending.hasPendingInput(uptime: now) ? .runAfterDispatch(target: target) : .run
    }

    /// The due pass waited for input already (a hold began and no pass ran since): it is not held for
    /// input again elsewhere (``CEFPumpFrameDeadline``), so its wait keeps this one bound.
    var isHolding: Bool { heldUntil != nil }

    /// A pass ran, or no pass waits any more: the next hold starts its own bound.
    func holdEnded() {
        heldUntil = nil
    }

    /// The next frame deadline after `start`, or one refresh after it, whichever comes first.
    private func holdDeadline(from start: TimeInterval) -> TimeInterval {
        let bound = start + refresh
        guard var frame = frameTarget(), frame.isFinite else { return bound }
        // The last tick's frame may be shown already; the next is one refresh later. A deadline
        // within the timer's slop is this instant's frame: the next one is the deadline.
        if frame <= start + Self.slop {
            frame += (((start + Self.slop - frame) / refresh).rounded(.down) + 1) * refresh
        }
        return min(bound, frame)
    }
}

/// The end of each input's dispatch, with where it went: what ``CEFPumpInputPolicy`` follows.
/// ``CEFPumpTapDispatches`` is the app's; tests drive their own.
protocol CEFPumpInputDispatches: AnyObject {
    /// Calls `handler` after each key, mouse button, scroll and drag the app dispatched, until the
    /// returned subscription is cancelled or released.
    func observeDispatchEnd(_ handler: @escaping (InputTarget) -> Void) -> InputSubscription
}

/// ``CEFPumpInputDispatches`` from the app's one input tap: its dispatch end
/// (`InputEventTap.observeDispatchEnd`), on every path and outside the event's dispatch scope, for the
/// input that counts as pending (`SessionInputPending.Kinds`). Pointer moves stream at the pointer's
/// rate and are not followed.
final class CEFPumpTapDispatches: CEFPumpInputDispatches {
    /// The classes whose dispatch ends a hold.
    static let followedClasses: InputEventClasses = [.key, .button, .scroll, .drag]

    private let tap: InputEventTap
    private let pages: ChromiumPageWindowClassifier

    /// - Parameters:
    ///   - tap: The app's one input tap.
    ///   - pages: What tells a Chromium page window (the pump's board shares it for its focus check).
    init(tap: InputEventTap, pages: ChromiumPageWindowClassifier = ChromiumPageWindowClassifier()) {
        self.tap = tap
        self.pages = pages
    }

    /// - Parameters:
    ///   - tap: The app's one input tap.
    ///   - pageWindowClass: Chromium's page window class, nil until it is registered (a test passes
    ///     its own subclass).
    convenience init(tap: InputEventTap, pageWindowClass: @escaping () -> AnyClass?) {
        self.init(tap: tap, pages: ChromiumPageWindowClassifier(pageWindowClass: pageWindowClass))
    }

    func observeDispatchEnd(_ handler: @escaping (InputTarget) -> Void) -> InputSubscription {
        tap.observeDispatchEnd(Self.followedClasses) { [weak self] event, outcome in
            guard let self else { return }
            handler(self.target(of: event, outcome: outcome))
        }
    }

    /// Where an event went: a Chromium page when AppKit delivered it to a page window (`CefNSWindow`,
    /// a page or its DevTools; a key goes to it while it is key, a pointer event while it is under the
    /// pointer), anything else otherwise. An event cmux consumed never reached Chromium. O(1), no
    /// allocation once the class is found.
    func target(of event: NSEvent, outcome: InputEventTap.DispatchOutcome) -> InputTarget {
        guard outcome == .delivered, let window = event.window else { return .other }
        return pages.isPage(window) ? .chromiumPage : .other
    }
}
