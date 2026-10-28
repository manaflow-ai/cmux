public import AppKit
import CmuxNextInputCore
public import CmuxNextSignposts

extension InputFrameSignpost.Kind {
    /// The kind `NSApplication.sendEvent` stamps for an event of `type`: the person's key presses (whose pastes and
    /// input method commits take their timestamp), presses, releases, drags and scrolls; nil for the rest and for the
    /// app's synthetic input (`SyntheticInput`), as Chrome's EventLatency kinds leave out moves and synthetic events.
    ///
    /// - Parameters:
    ///   - type: The event's type.
    ///   - synthetic: The event is the app's own input, not a person's.
    public init?(_ type: NSEvent.EventType, synthetic: Bool) {
        guard !synthetic else { return nil }
        switch type {
        case .keyDown: self = .key
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: self = .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: self = .mouseUp
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: self = .drag
        case .scrollWheel: self = .scroll
        default: return nil
        }
    }

    /// Whether `action` is a text command that pastes (``InputFrameSignpost/Kind/paste``).
    public static func pastes(_ action: Selector) -> Bool {
        action == #selector(NSText.paste(_:)) || action == #selector(NSTextView.pasteAsPlainText(_:))
            || action == #selector(NSTextView.pasteAsRichText(_:))
    }
}

extension InputFrameSignpost {
    /// Runs the dispatch of `event` (`body`) as one stamped event: ``willDispatch(_:eventTimestamp:)`` with its kind
    /// and timestamp before it, ``didDispatch(_:changedContent:)`` with what it left for the commit after it.
    ///
    /// - Parameters:
    ///   - event: The event `sendEvent` got.
    ///   - synthetic: The event is the app's own input (no stamp).
    ///   - layoutTookScroll: Whether the layout took the scroll event, read after the dispatch.
    ///   - body: The dispatch.
    // perf-hot: 100ns main-turn
    public func dispatching(_ event: NSEvent, synthetic: Bool, layoutTookScroll: () -> Bool, _ body: () -> Void) {
        let stamp = willDispatch(Kind(event.type, synthetic: synthetic), eventTimestamp: event.timestamp)
        defer {
            didDispatch(stamp, changedContent: InputLatencyDispatch.leftContent(in: event.window, layoutTookScroll: layoutTookScroll()))
        }
        body()
    }
}

extension InputLatencyDispatch {
    /// Whether an event's dispatch left content for the turn's commit (Chrome's `caused_frame_update`): the layout
    /// took the scroll, or the event's window or the cmux window that holds it has views waiting to display or lay
    /// out, as ``didDispatch(_:layoutTookScroll:)`` decides for a latency slot.
    ///
    /// - Parameters:
    ///   - window: The event's window.
    ///   - layoutTookScroll: The layout took the scroll event.
    public static func leftContent(in window: NSWindow?, layoutTookScroll: Bool) -> Bool {
        if layoutTookScroll { return true }
        guard let window else { return false }
        if windowHasPendingDisplay(window) { return true }
        let owner = InputEventRecord.ownerWindow(of: window)
        return owner !== window && windowHasPendingDisplay(owner)
    }
}
