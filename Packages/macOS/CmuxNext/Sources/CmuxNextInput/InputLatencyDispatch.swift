public import AppKit
public import CmuxNextInputCore

/// The input latency part of `NSApplication.sendEvent`: one slot per tracked event, opened before the
/// event is dispatched and finished right after, closed by the tracker at the turn's commit.
///
/// ``InputLatencySampling`` decides which events open a slot and their kind, ``InputTargetClassifier`` where they
/// land. After the dispatch the slot gets `dispatchEnd`, the layout's target when the layout took the scroll, and
/// whether the dispatch left a change for the turn's commit to show (Chrome's `caused_frame_update`, which the ledger
/// reads to drop pointer and scroll slots that changed nothing; key slots are kept either way). The app's own
/// synthetic input (`SyntheticInput`, `debug.key`, `debug.mouse`) is labelled
/// ``CmuxNextInputCore/InputEntrypoint/automation`` so the person's histograms leave it out. Key presses and scrolls
/// also carry the older `key.frame` and `key.scroll_frame` intervals (``InputFrameInterval``), so `sendEvent` has one
/// classification and one commit boundary per turn for all three. While a key press's slot is in dispatch, its text
/// view's input method call stamps `textInputStart` and `textInputEnd` through ``textInput``.
///
/// A slot's frame update comes from what AppKit holds for the commit once the dispatch returned (views marked for
/// display or layout, in the event's window or the window that presents it) or the layout taking the scroll (it
/// moves its content in the turn), or from the commit itself when it ran inside the dispatch (the tracker). A surface
/// that draws outside AppKit (the terminal's Metal layer, a Chromium or WebKit page) marks its own slot when its frame
/// lands (``InputLatencyTracker/markCausedFrameUpdate(_:)``); nothing is assumed for it here.
///
/// ```swift
/// let slot = inputLatency.willDispatch(event, synthetic: isSynthetic, keyWindow: keyWindow)
/// defer { if let slot { inputLatency.didDispatch(slot, layoutTookScroll: inputDispatch.layoutTookScroll) } }
/// ```
@MainActor
public final class InputLatencyDispatch {
    /// A window's display refresh interval in seconds: how often a drag opens a slot.
    public typealias FrameInterval = @MainActor (NSWindow?) -> TimeInterval
    /// Whether `window`'s views were changed by the dispatch and wait for the next display pass.
    public typealias WindowChanged = @MainActor (NSWindow) -> Bool

    /// One slot opened for an event in dispatch.
    public struct Slot {
        public let token: InputLatencyToken
        public let kind: InputEventKind
        public let target: InputTarget
        /// The window that presents the response: the event's window, or the cmux window that holds it when it is a
        /// Chromium page's child window (`InputEventRecord.ownerWindow(of:)`).
        public let window: NSWindow?
        /// The event's own window (a page, a popover, a panel).
        public let eventWindow: NSWindow?
        /// A key down's slot: the key down whose dispatch this one runs inside, which ``textInput`` goes back to.
        let outerKeyDown: TextInputStage.KeyDown?
    }

    /// The tracker the slots open in.
    public let tracker: InputLatencyTracker
    /// Stamps the text input call of the key down in dispatch (``TextInputStage``).
    public let textInput: TextInputStage
    private let classifier: InputTargetClassifier
    private let frameInterval: FrameInterval
    private let windowChanged: WindowChanged
    private var sampling = InputLatencySampling()
    /// The target of the current press: its release and drags land there.
    private var pressTarget: InputTarget?
    /// The target of the current scroll gesture: its updates and momentum land there.
    private var scrollTarget: InputTarget?
    /// The refresh interval of the current press's window, read once per press.
    private var dragFrameInterval: TimeInterval = 1.0 / 60
    /// The slot of the current frame interval's first drag, which later drags in that interval join.
    private var dragToken: InputLatencyToken?
    /// Drags of a frame interval whose drag slot already closed (its turn committed): the next drag slot counts them.
    private var carriedDrags: UInt16 = 0

    /// - Parameters:
    ///   - tracker: The tracker the slots open in.
    ///   - classifier: Finds each event's target.
    ///   - frameInterval: A window's refresh interval (default: its screen's shortest).
    ///   - windowChanged: Whether a window has views waiting to be displayed or laid out (default: AppKit's flags).
    public init(tracker: InputLatencyTracker, classifier: InputTargetClassifier,
                frameInterval: @escaping FrameInterval = InputLatencyDispatch.screenFrameInterval,
                windowChanged: @escaping WindowChanged = InputLatencyDispatch.windowHasPendingDisplay) {
        self.tracker = tracker
        textInput = TextInputStage(tracker: tracker)
        self.classifier = classifier
        self.frameInterval = frameInterval
        self.windowChanged = windowChanged
    }

    /// Opens the slot of `event` when it is tracked; call before dispatching it.
    ///
    /// - Parameters:
    ///   - event: The event `sendEvent` got.
    ///   - synthetic: The app's own synthetic input, not a person's.
    ///   - keyWindow: The window a key goes to (read for key downs only).
    /// - Returns: The open slot, or nil for an untracked event, a drag that joined its frame's slot, or a full table.
    // perf-hot: 0.5us key-dispatch
    public func willDispatch(_ event: NSEvent, synthetic: Bool, keyWindow: @autoclosure () -> NSWindow?) -> Slot? {
        guard let type = InputEventType(event.type) else { return nil }
        let phase = type == .scrollWheel ? InputEventRecord.scrollPhase(of: event) : .none
        return open(type, scrollPhase: phase, keyCode: Self.keyCode(of: event, type: type), timestamp: event.timestamp,
                    window: event.window, synthetic: synthetic, keyWindow: keyWindow(),
                    underPointer: { classifier.pointerTarget(of: event) })
    }

    /// ``willDispatch(_:synthetic:keyWindow:)`` for a synthesized event the app delivers to `view` in `window` itself
    /// instead of through `sendEvent` (`debug.mouse` scrolls, whose events have no window).
    ///
    /// - Parameters:
    ///   - event: The synthesized event.
    ///   - window: The window it is delivered in.
    ///   - view: The view it is delivered to.
    /// - Returns: The open slot, as ``willDispatch(_:synthetic:keyWindow:)``.
    public func willDeliver(_ event: NSEvent, in window: NSWindow, to view: NSView?) -> Slot? {
        guard let type = InputEventType(event.type) else { return nil }
        let phase = type == .scrollWheel ? InputEventRecord.scrollPhase(of: event) : .none
        return open(type, scrollPhase: phase, keyCode: Self.keyCode(of: event, type: type), timestamp: event.timestamp,
                    window: window, synthetic: true,
                    keyWindow: window, underPointer: { classifier.classify(view: view, in: window) })
    }

    /// ``willDispatch(_:synthetic:keyWindow:)`` with the event's fields; `underPointer` hit-tests the event's point.
    func open(_ type: InputEventType, scrollPhase: InputScrollPhase, keyCode: UInt16 = 0, timestamp: TimeInterval,
              window: NSWindow?,
              synthetic: Bool, keyWindow: @autoclosure () -> NSWindow?,
              underPointer: () -> InputTarget) -> Slot? {
        if type.isButtonDown {
            dragFrameInterval = frameInterval(window)
            dragToken = nil
            carriedDrags = 0
        }
        let kind: InputEventKind
        let target: InputTarget
        switch sampling.decide(type, scrollPhase: scrollPhase, timestamp: timestamp, frameInterval: dragFrameInterval) {
        case .skip:
            return nil
        case .coalesceDrag:
            // Joins the frame's drag slot while its turn has not committed; after that, the next drag slot counts it.
            if let dragToken, tracker.table.addCoalesced(dragToken, 1) { return nil }
            carriedDrags = carriedDrags == .max ? .max : carriedDrags + 1
            return nil
        case let .open(decided, source):
            kind = decided
            target = resolve(source, kind: decided, keyWindow: keyWindow(), underPointer: underPointer)
        }
        let presenting = window.map(InputEventRecord.ownerWindow(of:))
        let token = tracker.begin(kind: kind, target: target, entrypoint: synthetic ? .automation : .person,
                                  eventTimestamp: timestamp, window: presenting,
                                  frameInterval: Self.frameInterval(of: kind, scrollPhase: scrollPhase), keyCode: keyCode)
        if kind == .drag {
            dragToken = token
            if let token, carriedDrags > 0 {
                tracker.table.addCoalesced(token, carriedDrags)
                carriedDrags = 0
            }
        }
        guard let token else { return nil }
        let outerKeyDown = kind == .keyPress ? textInput.keyDownDispatchBegan(token, timestamp: timestamp) : nil
        return Slot(token: token, kind: kind, target: target, window: presenting, eventWindow: window,
                    outerKeyDown: outerKeyDown)
    }

    /// Finishes `slot` after its event's dispatch returned.
    ///
    /// - Parameters:
    ///   - slot: The slot ``willDispatch(_:synthetic:keyWindow:)`` opened for the event.
    ///   - layoutTookScroll: The layout took the scroll event (a strip, row, area or canvas scroll): the slot and the
    ///     rest of its gesture are the layout's.
    // perf-hot: 0.2us key-dispatch
    public func didDispatch(_ slot: Slot, layoutTookScroll: Bool) {
        tracker.endDispatch(slot.token)
        if slot.kind == .keyPress { textInput.keyDownDispatchEnded(restoring: slot.outerKeyDown) }
        if layoutTookScroll, slot.target != .layout {
            tracker.setTarget(slot.token, .layout)
            scrollTarget = .layout
        }
        if layoutTookScroll || changed(slot.eventWindow) || (slot.window !== slot.eventWindow && changed(slot.window)) {
            tracker.markCausedFrameUpdate(slot.token)
        }
    }

    private func changed(_ window: NSWindow?) -> Bool {
        window.map(windowChanged) ?? false
    }

    private func resolve(_ source: InputLatencySampling.TargetSource, kind: InputEventKind,
                         keyWindow: @autoclosure () -> NSWindow?, underPointer: () -> InputTarget) -> InputTarget {
        let isScroll = kind != .mousePress && kind != .mouseRelease && kind != .drag
        switch source {
        case .keyboardFocus:
            return classifier.keyTarget(in: keyWindow())
        case .underPointer:
            let target = underPointer()
            if isScroll { scrollTarget = target } else { pressTarget = target }
            return target
        case .latched:
            if let latched = isScroll ? scrollTarget : pressTarget { return latched }
            let target = underPointer()
            if isScroll { scrollTarget = target } else { pressTarget = target }
            return target
        }
    }

    /// The virtual key code of a key down or up (pairs the press with its release, ``InteractionLatency``), else 0:
    /// `NSEvent.keyCode` raises for any other type.
    static func keyCode(of event: NSEvent, type: InputEventType) -> UInt16 {
        type == .keyDown || type == .keyUp ? event.keyCode : 0
    }

    /// The older interval a slot of `kind` carries: `key.frame` for a key press, `key.scroll_frame` with the scroll's
    /// phase for a scroll slot; nil for the others.
    nonisolated static func frameInterval(of kind: InputEventKind, scrollPhase: InputScrollPhase) -> InputFrameInterval? {
        switch kind {
        case .keyPress:
            return .key
        case .scrollBegin, .scrollFirstUpdate, .scrollUpdate, .scrollMomentum:
            switch scrollPhase {
            case .began: return .scroll(.began)
            case .changed: return .scroll(.changed)
            case .momentum: return .scroll(.momentum)
            case .none: return .scroll(.wheel)
            case .mayBegin, .ended, .cancelled, .momentumEnded: return nil
            }
        case .keyRelease, .flags, .mousePress, .mouseRelease, .pointerMove, .drag, .scrollEnd, .magnify:
            return nil
        }
    }

    /// The shortest refresh interval of `window`'s screen, or 60 Hz without one.
    public static func screenFrameInterval(_ window: NSWindow?) -> TimeInterval {
        window?.screen?.minimumRefreshInterval ?? 1.0 / 60
    }

    /// Whether `window` has views marked for display or its content view for layout.
    public static func windowHasPendingDisplay(_ window: NSWindow) -> Bool {
        window.viewsNeedDisplay || window.contentView?.needsLayout == true
    }
}
