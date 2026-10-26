public import AppKit
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
///
/// The App's composition root makes one and passes it to the application object and the key router:
///
/// ```swift
/// let inputDispatch = InputDispatchContext(discreteInput: { mainWork.noteDiscreteInput(expectsFrame: $0) })
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
    /// Discrete dispatches on ``stack``: while there is one, ``nestedRunLoopObserver`` is on the main run loop.
    private var openDiscrete = 0
    /// Reports the open discrete inputs at the first wait of a run loop nested in their dispatch
    /// (``nestedRunLoopWillWait()``).
    private var nestedRunLoopObserver: CFRunLoopObserver?
    /// Times each scroll event dispatched here to the frame that shows it (`key.scroll_frame`).
    private let scrollFrames: any ScrollFrameTiming
    /// Told about each discrete input whether its turn expects a frame (``report(_:)``).
    private let discreteInput: @MainActor (_ expectsFrame: Bool) -> Void
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
    ///   - displayPending: Whether a view asked for display during the dispatch (the default reads the event's
    ///     window and the key window, ``windowsNeedDisplay(for:)``; tests inject one).
    public init(scrollFrames: any ScrollFrameTiming = NoScrollFrameTiming(),
                discreteInput: @escaping @MainActor (_ expectsFrame: Bool) -> Void = { _ in },
                displayPending: @escaping @MainActor (NSEvent) -> Bool = InputDispatchContext.windowsNeedDisplay(for:)) {
        self.scrollFrames = scrollFrames
        self.discreteInput = discreteInput
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

    /// The innermost event being dispatched, nil between dispatches.
    public var event: NSEvent? { stack.last?.event }

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
        defer {
            let dispatch = stack.removeLast()
            if dispatch.isScroll { scrollFrames.end(target: dispatch.layoutTook ? .layout : .content) }
            if dispatch.isDiscrete {
                watchNestedRunLoops(opening: false)
                _ = report(dispatch)
            } else if let outer = stack.indices.last {
                stack[outer].expectsFrame = stack[outer].expectsFrame || dispatch.expectsFrame
            }
        }
        return try body()
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
        } else if !opening, openDiscrete == 0, let observer = nestedRunLoopObserver {
            CFRunLoopObserverInvalidate(observer)
            nestedRunLoopObserver = nil
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
