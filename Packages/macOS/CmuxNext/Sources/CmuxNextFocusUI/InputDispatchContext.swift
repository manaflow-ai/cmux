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
/// It also tells the main-thread scheduler about each discrete input (a key-down or a mouse-down, Chrome's
/// discrete events in `main_thread_event_queue.h`) when its dispatch ends, and whether the turn expects a frame
/// (Chrome's `is_frame_expected_after_discrete_input` in `main_thread_scheduler_impl.cc`): an action effect that
/// changed something (``noteFrameExpected()``), a view that asked for display, or a key the terminal took.
/// Key-ups, moves, drags, scrolls and modifier changes report nothing.
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
    /// One dispatch in progress: its event, whether it is a timed scroll, whether the layout took it, and
    /// whether something in it expects a frame.
    private struct Dispatch {
        let event: NSEvent
        let isScroll: Bool
        var layoutTook = false
        var expectsFrame = false
    }

    private var stack: [Dispatch] = []
    /// Times each scroll event dispatched here to the frame that shows it (`key.scroll_frame`).
    private let scrollFrames: any ScrollFrameTiming
    /// Told at the end of each discrete input's dispatch whether the turn expects a frame.
    private let discreteInput: @MainActor (_ expectsFrame: Bool) -> Void
    /// Whether a window of `event` still has a display request pending when its dispatch ends.
    private let displayPending: @MainActor (NSEvent) -> Bool

    /// A context with no event being dispatched.
    ///
    /// - Parameters:
    ///   - scrollFrames: Times each scroll event dispatched here (the App passes ``ScrollFrameSignpost``; the
    ///     default records nothing).
    ///   - discreteInput: Told once per discrete input, when its dispatch ends, whether the turn expects a frame
    ///     (the App passes its main-thread scheduler's `noteDiscreteInput(expectsFrame:)`; the default ignores it).
    ///   - displayPending: Whether a view asked for display during the dispatch (the default reads the event's
    ///     window and the key window, ``windowsNeedDisplay(for:)``; tests inject one).
    public init(scrollFrames: any ScrollFrameTiming = NoScrollFrameTiming(),
                discreteInput: @escaping @MainActor (_ expectsFrame: Bool) -> Void = { _ in },
                displayPending: @escaping @MainActor (NSEvent) -> Bool = InputDispatchContext.windowsNeedDisplay(for:)) {
        self.scrollFrames = scrollFrames
        self.discreteInput = discreteInput
        self.displayPending = displayPending
    }

    /// The dispatch in progress changed something that shows in the next frame (an action returned an applied
    /// or waiting effect, a key reached the terminal). Nothing between dispatches: a CLI or socket run is not input.
    public func noteFrameExpected() {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].expectsFrame = true
    }

    /// Whether `type` is a discrete input the scheduler hears about: a key-down or a mouse-down.
    public static func isDiscreteInput(_ type: NSEvent.EventType) -> Bool {
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
    /// input reports whether its turn expects a frame when `body` returns; the same event dispatched again inside
    /// it (`debug.key` sending its key through the app) reports once, from the outer dispatch.
    ///
    /// - Parameters:
    ///   - event: The event `body` dispatches.
    ///   - body: The dispatch.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    public func dispatching<T>(_ event: NSEvent, _ body: () throws -> T) rethrows -> T {
        let isScroll = event.type == .scrollWheel
        if isScroll { scrollFrames.begin(phase: scrollFramePhase(of: event), eventTimestamp: event.timestamp) }
        stack.append(Dispatch(event: event, isScroll: isScroll))
        defer {
            let dispatch = stack.removeLast()
            if dispatch.isScroll { scrollFrames.end(target: dispatch.layoutTook ? .layout : .content) }
            if let outer = stack.indices.last, stack[outer].event === dispatch.event {
                stack[outer].expectsFrame = stack[outer].expectsFrame || dispatch.expectsFrame
            } else if Self.isDiscreteInput(dispatch.event.type) {
                discreteInput(dispatch.expectsFrame || displayPending(dispatch.event))
            }
        }
        return try body()
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
