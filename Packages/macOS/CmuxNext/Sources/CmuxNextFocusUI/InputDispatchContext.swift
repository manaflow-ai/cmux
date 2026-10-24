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
/// The App's composition root makes one and passes it to the application object and the key router:
///
/// ```swift
/// let inputDispatch = InputDispatchContext()
/// registry.dispatchingInputEvent = { inputDispatch.event }
/// ```
@MainActor
public final class InputDispatchContext {
    /// One dispatch in progress: its event, whether it is a timed scroll, and whether the layout took it.
    private struct Dispatch {
        let event: NSEvent
        let isScroll: Bool
        var layoutTook = false
    }

    private var stack: [Dispatch] = []
    /// Times each scroll event dispatched here to the frame that shows it (`key.scroll_frame`).
    private let scrollFrames: any ScrollFrameTiming

    /// A context with no event being dispatched.
    ///
    /// - Parameter scrollFrames: Times each scroll event dispatched here (the App passes
    ///   ``ScrollFrameSignpost``; the default records nothing).
    public init(scrollFrames: any ScrollFrameTiming = NoScrollFrameTiming()) {
        self.scrollFrames = scrollFrames
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
    /// it (`key.scroll_frame`): from its dispatch to the commit that ends the turn, with who took it.
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
