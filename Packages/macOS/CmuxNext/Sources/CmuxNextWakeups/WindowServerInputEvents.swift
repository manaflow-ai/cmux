public import AppKit
public import CmuxNextInputCore

/// The production ``SessionInputEvents``: `CGEventSource`'s combined session state, `NSApp`, the
/// key window's screen, the window under the pointer, and one subscription to the app's input tap
/// for the input events AppKit dispatches.
@MainActor
public final class WindowServerInputEvents: SessionInputEvents {
    /// The app's input tap (`InputEventTap` in CmuxNextInput, passed by the composition root).
    private let input: any InputObserving
    private var subscription: InputSubscription?
    /// `kCGAnyInputEventType` (`~0`, a C macro Swift does not import).
    private let anyInput = CGEventType(rawValue: ~0)

    /// - Parameter input: The app's input tap: this observes its keys, modifier changes, mouse
    ///   buttons, pointer motion and scrolls.
    public init(input: any InputObserving) {
        self.input = input
    }

    /// Seconds since the window server's last input event of any type, in the session.
    public func secondsSinceLastInput() -> TimeInterval {
        // Without the any-input type the answer is "just now", which sends the caller to the
        // per-type queries: slower, never wrong.
        guard let anyInput else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// Seconds since the window server's last `type` event, in the session.
    public func secondsSinceLastEvent(_ type: CGEventType) -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
    }

    /// Whether cmux is the active app.
    public var isAppActive: Bool { NSApp?.isActive ?? false }

    /// The frame period of the key window's display (else the main display's).
    public var refreshInterval: TimeInterval {
        (NSApp?.keyWindow?.screen ?? NSScreen.main)?.minimumRefreshInterval ?? 1.0 / 60
    }

    /// Whether the topmost window under the pointer is one of cmux's.
    public var pointerIsOverAppWindow: Bool {
        guard let app = NSApp else { return false }
        // 0: the topmost window at the point, of any app.
        let number = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        return number > 0 && app.window(withWindowNumber: number) != nil
    }

    /// Calls `dispatched` for each input event AppKit dispatches in this app, from the input tap; once per instance.
    public func observeDispatch(_ dispatched: @escaping @MainActor @Sendable (SessionInputPending.Dispatched) -> Void) {
        guard subscription == nil else { return }
        subscription = input.observe(SessionInputPending.Dispatched.observedClasses) { record in
            dispatched(SessionInputPending.Dispatched(record))
        }
    }
}

extension SessionInputPending.Dispatched {
    /// The input the pending-input check follows: keys, modifier changes, mouse buttons, pointer
    /// motion and scrolls (no trackpad gestures).
    public static let observedClasses: InputEventClasses = [.key, .flags, .button, .pointerMove, .drag, .scroll]

    // perf-hot: 100ns main-turn (every key, button, move, drag and scroll the app dispatches)
    /// What ``SessionInputPending`` needs to know about the dispatched event `record`.
    public init(_ record: InputEventRecord) {
        self.init(timestamp: record.timestamp, kind: Kind(record))
    }
}

extension SessionInputPending.Dispatched.Kind {
    /// The kind of the dispatched event `record`.
    public init(_ record: InputEventRecord) {
        switch record.type {
        case .keyDown, .rightMouseDown, .otherMouseDown: self = .keyOrClick
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseUp: self = .leftMouseUp
        case .leftMouseDragged: self = .leftDrag
        case .scrollWheel:
            let phases = Self.phases(record.scrollPhase)
            self = .scroll(phase: phases.phase, momentum: phases.momentum)
        case .keyUp, .flagsChanged, .rightMouseUp, .otherMouseUp, .mouseMoved, .rightMouseDragged, .otherMouseDragged,
             .magnify, .rotate, .swipe, .smartMagnify, .pressure, .mouseEntered, .mouseExited:
            self = .other
        }
    }

    /// The gesture and momentum phases (`NSEvent.phase`, `NSEvent.momentumPhase`) of a scroll whose
    /// record says `phase`, as ``SessionInputPending/ScrollLatching`` reads them.
    static func phases(_ phase: InputScrollPhase) -> (phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        switch phase {
        case .none: ([], [])
        case .mayBegin: (.mayBegin, [])
        case .began: (.began, [])
        case .changed: (.changed, [])
        case .ended: (.ended, [])
        case .cancelled: (.cancelled, [])
        case .momentum: ([], .changed)
        case .momentumEnded: ([], .ended)
        }
    }
}
