public import AppKit
public import CmuxNextInputCore

/// The input latency part of `NSApplication.sendEvent` (p04-input-005): one slot per tracked event, opened before the
/// event is dispatched and finished right after, closed by the tracker at the turn's commit.
///
/// ``InputLatencySampling`` decides which events open a slot and their kind, ``InputTargetClassifier`` where they
/// land. After the dispatch the slot gets `dispatchEnd`, the layout's target when the layout took the scroll, and
/// whether the dispatch changed what is on screen (Chrome's `caused_frame_update`, which the ledger reads to drop
/// pointer and scroll slots that changed nothing; key slots are kept either way). The app's own synthetic input
/// (`SyntheticInput`, `debug.key`, `debug.mouse`) is labelled ``CmuxNextInputCore/InputEntrypoint/automation`` so the
/// person's histograms leave it out.
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
        /// The event's window: the one its frame update is looked for in.
        public let window: NSWindow?
    }

    /// The tracker the slots open in.
    public let tracker: InputLatencyTracker
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

    /// - Parameters:
    ///   - tracker: The tracker the slots open in.
    ///   - classifier: Finds each event's target.
    ///   - frameInterval: A window's refresh interval (default: its screen's shortest).
    ///   - windowChanged: Whether a window has views waiting to be displayed or laid out (default: AppKit's flags).
    public init(tracker: InputLatencyTracker, classifier: InputTargetClassifier,
                frameInterval: @escaping FrameInterval = InputLatencyDispatch.screenFrameInterval,
                windowChanged: @escaping WindowChanged = InputLatencyDispatch.windowHasPendingDisplay) {
        self.tracker = tracker
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
        return open(type, scrollPhase: phase, timestamp: event.timestamp, window: event.window, synthetic: synthetic,
                    keyWindow: keyWindow(), underPointer: { classifier.pointerTarget(of: event) })
    }

    /// ``willDispatch(_:synthetic:keyWindow:)`` with the event's fields; `underPointer` hit-tests the event's point.
    func open(_ type: InputEventType, scrollPhase: InputScrollPhase, timestamp: TimeInterval, window: NSWindow?,
              synthetic: Bool, keyWindow: @autoclosure () -> NSWindow?,
              underPointer: () -> InputTarget) -> Slot? {
        if type.isButtonDown { dragFrameInterval = frameInterval(window) }
        let kind: InputEventKind
        let target: InputTarget
        switch sampling.decide(type, scrollPhase: scrollPhase, timestamp: timestamp, frameInterval: dragFrameInterval) {
        case .skip:
            return nil
        case .coalesceDrag:
            if let dragToken { tracker.table.addCoalesced(dragToken, 1) }
            return nil
        case let .open(decided, source):
            kind = decided
            target = resolve(source, kind: decided, keyWindow: keyWindow(), underPointer: underPointer)
        }
        let token = tracker.begin(kind: kind, target: target, entrypoint: synthetic ? .automation : .person,
                                  eventTimestamp: timestamp, window: window)
        if kind == .drag { dragToken = token }
        guard let token else { return nil }
        return Slot(token: token, kind: kind, target: target, window: window)
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
        var target = slot.target
        if layoutTookScroll, target != .layout {
            target = .layout
            tracker.table.setTarget(slot.token, .layout)
            scrollTarget = .layout
        }
        var updated = Self.drawsItself(target) || layoutTookScroll
        if !updated, let window = slot.window { updated = windowChanged(window) }
        if updated { tracker.markCausedFrameUpdate(slot.token) }
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

    /// Surfaces that draw outside AppKit's display pass (Metal, Chromium's and WebKit's compositors): AppKit's flags
    /// never see their frames, so an input they take counts as a frame update.
    static func drawsItself(_ target: InputTarget) -> Bool {
        switch target {
        case .terminal, .chromiumPage, .webkitPage, .agentPane: true
        case .textView, .layout, .sidebar, .palette, .other: false
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
