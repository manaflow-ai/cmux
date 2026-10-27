public import AppKit
import CmuxNextActions
public import CmuxNextSignposts

/// The input event being dispatched now: the one source the key router, the menu key gate, the action
/// signposts' input age and the key-down checks read.
///
/// `NSApplication.sendEvent` dispatches each event inside ``dispatching(_:_:)`` (the App's `CmuxApplication`),
/// and so does a key the App routes itself outside `sendEvent` (`debug.key`, a held key replayed: the key
/// router's `dispatchingSynthetic`). Nested dispatches (a synthetic event sent from inside another dispatch, a
/// menu or modal run loop) see the innermost event. `NSApp.currentEvent` is never read: it is the last event
/// AppKit dequeued, not the one given to `sendEvent`, and it keeps that event after its dispatch ends, so a socket
/// run later would report an old key press.
///
/// It also tells the main-thread scheduler about each discrete input (Chrome's non-continuous events,
/// `IsContinuousEvent` in third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc) and whether
/// its turn expects a frame (Chrome's `is_frame_expected_after_discrete_input` in
/// third_party/blink/renderer/platform/scheduler/main_thread/main_thread_scheduler_impl.cc): an action ran
/// (``noteFrameExpected()``), a view asked for display, or the terminal took the key. A key-down or mouse-down
/// always reports; a mouse-up reports only when its turn expects a frame (a button acts on release). It reports
/// when its dispatch ends, or earlier, at the first wait of a run loop nested in it (a menu, a drag or a button's
/// tracking loop draws its frames there). Key-ups, moves, drags, scrolls and modifier changes report nothing.
/// Around the discrete dispatches it says when the first begins and the last ends (after its report), so the
/// scheduler's input-response pass is on the run loop before any nested loop waits.
///
/// The App's composition root makes one and passes it to the application object and the key router:
///
/// ```swift
/// let inputDispatch = InputDispatchContext(discreteInput: { mainWork.noteDiscreteInput(expectsFrame: $0) },
///                                          discreteDispatch: { mainWork.noteDiscreteDispatch(began: $0) })
/// registry.dispatchingInputEvent = { inputDispatch.event }
/// registry.effectExpectsFrame = { inputDispatch.noteFrameExpected() }
/// ```
@MainActor
public final class InputDispatchContext {
    /// One dispatch in progress: its event, whether it is a timed scroll, whether it reports a discrete input,
    /// whether the layout took it, whether something in it expects a frame, and what it reported so far.
    private struct Dispatch {
        let event: NSEvent
        let isScroll: Bool
        let isDiscrete: Bool
        var layoutTook = false
        var expectsFrame = false
        /// The `expectsFrame` this discrete input last reported; nil before it reported.
        var reported: Bool?
    }

    private var stack: [Dispatch] = []
    /// The inputs ``answering(input:_:)`` hands in, innermost last.
    private var answered: [TimeInterval] = []
    /// Discrete dispatches on ``stack``: while there is one, ``nestedRunLoopObserver`` is on the main run loop.
    private var openDiscrete = 0
    /// Reports the open discrete inputs at the first wait of a run loop nested in their dispatch
    /// (``nestedRunLoopWillWait()``).
    private var nestedRunLoopObserver: CFRunLoopObserver?
    /// Times each scroll event dispatched here to the frame that shows it (`key.scroll_frame`).
    private let scrollFrames: any ScrollFrameTiming
    /// Told about each discrete input whether its turn expects a frame (``report(_:)``).
    private let discreteInput: @MainActor (_ expectsFrame: Bool) -> Void
    /// Told when the first discrete dispatch begins (true) and the last one ends (false).
    private let discreteDispatch: @MainActor (_ began: Bool) -> Void
    /// Whether a window of `event` still has a display request pending when its dispatch ends.
    private let displayPending: @MainActor (NSEvent) -> Bool

    /// A context with no event being dispatched.
    ///
    /// - Parameters:
    ///   - scrollFrames: Times each scroll event dispatched here (the App passes ``ScrollFrameSignpost``; the
    ///     default records nothing).
    ///   - discreteInput: Told about each discrete input, whether its turn expects a frame (the App passes its
    ///     main-thread scheduler's `noteDiscreteInput(expectsFrame:)`; the default ignores it). Once per input,
    ///     or twice when it reported early with no frame and its dispatch expected one later.
    ///   - discreteDispatch: Told true before the first discrete dispatch runs and false after the last one
    ///     reported (the App passes its scheduler's `noteDiscreteDispatch(began:)`; the default ignores it).
    ///   - displayPending: Whether a view asked for display during the dispatch (the default reads the event's
    ///     window and the key window, ``windowsNeedDisplay(for:)``; tests inject one).
    public init(scrollFrames: any ScrollFrameTiming = NoScrollFrameTiming(),
                discreteInput: @escaping @MainActor (_ expectsFrame: Bool) -> Void = { _ in },
                discreteDispatch: @escaping @MainActor (_ began: Bool) -> Void = { _ in },
                displayPending: @escaping @MainActor (NSEvent) -> Bool = InputDispatchContext.windowsNeedDisplay(for:)) {
        self.scrollFrames = scrollFrames
        self.discreteInput = discreteInput
        self.discreteDispatch = discreteDispatch
        self.displayPending = displayPending
    }

    /// The dispatch in progress changed something that shows in the next frame (an action ran, the terminal took
    /// a key). Nothing between dispatches: a CLI or socket run is not input.
    public func noteFrameExpected() {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].expectsFrame = true
    }

    /// Whether `type` is a discrete input: a key-down, a mouse-down or a mouse-up.
    public static func isDiscreteInput(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp: true
        default: false
        }
    }

    /// Whether a discrete input of `type` reports when its turn expects no frame: a key-down or a mouse-down (it
    /// starts the typing burst either way), not a mouse-up.
    static func reportsWithoutFrame(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown: true
        default: false
        }
    }

    /// Whether the window `event` went to, or the key window, has views waiting for display: the render pass
    /// at the end of this turn will draw.
    public static func windowsNeedDisplay(for event: NSEvent) -> Bool {
        event.window?.viewsNeedDisplay == true || NSApp?.keyWindow?.viewsNeedDisplay == true
    }

    /// The layout took the scroll event being dispatched (a strip, row, area or canvas scroll): its timing
    /// ends `target=layout`. Called by the layout's scroll routing; nothing between dispatches.
    public func noteLayoutTookScroll() {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].layoutTook = true
    }

    /// Whether the layout took the scroll event being dispatched (``noteLayoutTookScroll()``); false between dispatches.
    public var layoutTookScroll: Bool { stack.last?.layoutTook ?? false }

    /// The innermost event being dispatched, nil between dispatches.
    public var event: NSEvent? { stack.last?.event }

    /// The input a `switch.*` interval begun now answers (`switch.workspace`, `switch.tab`, `switch.pane_focus`), as an
    /// `NSEvent.timestamp`, the same input an action run's `action.*` row reads:
    /// - the key or click being dispatched (`ActionRegistry.inputTimestamp(of:)`);
    /// - else an input another process took and handed here with its request (``answering(input:_:)``: a page's click
    ///   or Return, which comes back a turn after its own dispatch);
    /// - else the press of the person's action run in progress (`ActionRunScope.inputTimestamp`), so a run a gate let
    ///   through, or a run's task after a daemon reply, switches with its press's age.
    ///
    /// Nil otherwise: a switch a socket, the CLI or a script starts has no input age however recent the last click was
    /// (`NSApp.currentEvent` keeps that click). Chrome stamps an input's latency with the event's own time and carries
    /// it with the work it causes across threads and processes (`EventMetrics`, cc/metrics/event_metrics.h).
    public var inputTimestamp: TimeInterval? {
        ActionRegistry.inputTimestamp(of: event) ?? answered.last ?? ActionRunScope.current?.inputTimestamp
    }

    /// Runs `body` as the answer to a person's input another process dispatched (a page's click or key, whose request
    /// arrives here after that event's own dispatch ended): a switch `body` begins takes `input` as its input. Nil runs
    /// `body` with no such input. Synchronous: a task `body` starts does not keep it.
    ///
    /// - Parameters:
    ///   - input: The input's `NSEvent.timestamp` (seconds of system uptime), or nil.
    ///   - body: The work that answers it.
    /// - Returns: What `body` returns.
    public func answering<T>(input: TimeInterval?, _ body: () throws -> T) rethrows -> T {
        guard let input else { return try body() }
        answered.append(input)
        defer { _ = answered.popLast() }
        return try body()
    }

    /// Whether the innermost event being dispatched is a key-down.
    public var isKeyDown: Bool { stack.last?.event.type == .keyDown }

    /// Runs `body` with `event` as the event being dispatched. A scroll event is timed to the frame that shows
    /// it (`key.scroll_frame`): from its dispatch to the commit that ends the turn, with who took it. A discrete
    /// input reports whether its turn expects a frame when `body` returns, or at the first wait of a run loop nested
    /// in `body`. A dispatch nested in another (the same event sent through the app by `debug.key`, a move inside a
    /// tracking loop) hands its frame expectation to the outer one.
    ///
    /// - Parameters:
    ///   - event: The event `body` dispatches.
    ///   - body: The dispatch.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    public func dispatching<T>(_ event: NSEvent, _ body: () throws -> T) rethrows -> T {
        let isScroll = event.type == .scrollWheel
        if isScroll { scrollFrames.begin(phase: scrollFramePhase(of: event), eventTimestamp: event.timestamp) }
        let isDiscrete = Self.isDiscreteInput(event.type) && stack.last?.event !== event
        stack.append(Dispatch(event: event, isScroll: isScroll, isDiscrete: isDiscrete))
        if isDiscrete { watchNestedRunLoops(opening: true) }
        defer { endDispatch() }
        return try body()
    }

    /// Closes the innermost dispatch ``dispatching(_:_:)`` opened: its scroll frame, its report, or its frame
    /// expectation handed to the outer one.
    private func endDispatch() {
        guard let dispatch = stack.popLast() else { return }
        if dispatch.isScroll { scrollFrames.end(target: dispatch.layoutTook ? .layout : .content) }
        if dispatch.isDiscrete {
            _ = report(dispatch)
            watchNestedRunLoops(opening: false)
        } else if let outer = stack.indices.last {
            stack[outer].expectsFrame = stack[outer].expectsFrame || dispatch.expectsFrame
        }
    }

    /// A run loop nested in the open discrete inputs' dispatch is about to wait: its render pass draws what they
    /// changed so far, so each reports now rather than when its dispatch returns. The main run loop's own wait
    /// never comes while a dispatch is open (the dispatch runs inside that run loop's turn).
    func nestedRunLoopWillWait() {
        for index in stack.indices where stack[index].isDiscrete {
            stack[index].reported = report(stack[index])
        }
    }

    /// Reports `dispatch` unless it already said as much; returns what it has reported.
    private func report(_ dispatch: Dispatch) -> Bool? {
        let expects = dispatch.expectsFrame || displayPending(dispatch.event)
        let said = dispatch.reported
        guard said == nil || (expects && said == false), expects || Self.reportsWithoutFrame(dispatch.event.type) else { return said }
        discreteInput(expects)
        return expects
    }

    /// Keeps ``nestedRunLoopObserver`` on the main run loop (all common modes, event tracking and modal panels
    /// included) while a discrete dispatch is open, and off it otherwise.
    private func watchNestedRunLoops(opening: Bool) {
        openDiscrete += opening ? 1 : -1
        if opening, openDiscrete == 1 {
            // First of the wait's observers, so it reports before the Core Animation commit of that pass.
            let observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                              true, CFIndex.min) { [weak self] _, _ in
                // main-proof: the observer is added to the main run loop only (below).
                MainActor.assumeIsolated { self?.nestedRunLoopWillWait() }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
            nestedRunLoopObserver = observer
            discreteDispatch(true)
        } else if !opening, openDiscrete == 0, let observer = nestedRunLoopObserver {
            CFRunLoopObserverInvalidate(observer)
            nestedRunLoopObserver = nil
            discreteDispatch(false)
        }
    }
}

/// Which part of a scroll `event` is: momentum first (a coast carries no gesture phase), then the gesture
/// phase, and a mouse-wheel notch when it has neither.
private func scrollFramePhase(of event: NSEvent) -> ScrollFramePhase {
    if !event.momentumPhase.isEmpty { return .momentum }
    let phase = event.phase
    if phase.isEmpty { return .wheel }
    if phase.contains(.mayBegin) { return .touch }
    if phase.contains(.began) { return .began }
    if phase.contains(.ended) || phase.contains(.cancelled) { return .ended }
    return .changed
}
