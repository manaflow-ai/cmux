public import AppKit
public import CmuxNextInputCore

/// The text input part of a key down's dispatch: the input method server round trip that
/// `interpretKeyEvents` (or an `NSTextView`'s key handling) makes, stamped as the key's `textInputStart` and
/// `textInputEnd` so a Japanese or Korean input source's time shows apart from cmux's own dispatch.
///
/// Chromium sends a key down through `interpretKeyEvents` the same way before it forwards it to the renderer
/// (`-[RenderWidgetHostViewCocoa keyEvent:wasKeyEquivalent:]`, content/app_shim_remote_cocoa/
/// render_widget_host_view_cocoa.mm); its `EventMetrics` has no stage for that call, so these two are cmux's.
///
/// ``InputLatencyDispatch`` gives the stage the slot and the timestamp of the key down it dispatches, and takes them
/// back when that dispatch returns. A text view runs its input method call for a key down in
/// ``interpreting(_:_:)``. When that key down is the one in dispatch (same timestamp; a key the router sends to
/// another window keeps it), the stage reads the clock once before and once after (two clock reads, no
/// allocation). For any other key it only runs the call: a key typed earlier and replayed around `sendEvent` while
/// another key's dispatch is open (the launch picture's held keys), a key up, an untracked key, a full slot table.
/// So no slot gets another key's time. A call inside another (a re-sent chord) runs plainly: the outer call's two
/// stamps already cover it.
///
/// ```swift
/// func interpret(_ event: NSEvent) {
///     guard let textInputStage else { return interpretKeyEvents([event]) }
///     textInputStage.interpreting(event) { interpretKeyEvents([event]) }
/// }
/// ```
@MainActor
public final class TextInputStage {
    /// The key down being dispatched: its slot, and its event's timestamp, which tells its own input method call
    /// from another key's.
    public struct KeyDown: Equatable, Sendable {
        /// The key down's latency slot.
        public let token: InputLatencyToken
        /// The key down event's timestamp (seconds since boot).
        public let timestamp: TimeInterval
    }

    private let tracker: InputLatencyTracker
    /// The key down being dispatched, or nil.
    public private(set) var keyDown: KeyDown?
    /// Whether an ``interpreting(_:_:)`` call is running.
    private var isInterpreting = false

    /// - Parameter tracker: The tracker the key slots are open in.
    public init(tracker: InputLatencyTracker) {
        self.tracker = tracker
    }

    /// The dispatch of the key down whose slot is `token` began: its own text input call stamps that slot.
    ///
    /// - Parameters:
    ///   - token: The key down's slot.
    ///   - timestamp: The key down event's timestamp.
    /// - Returns: The key down whose dispatch this one runs inside, or nil; give it back to
    ///   ``keyDownDispatchEnded(restoring:)``.
    func keyDownDispatchBegan(_ token: InputLatencyToken, timestamp: TimeInterval) -> KeyDown? {
        let outer = keyDown
        keyDown = KeyDown(token: token, timestamp: timestamp)
        return outer
    }

    /// The key down's dispatch returned: the stage goes back to the key down whose dispatch it ran inside.
    ///
    /// - Parameter outer: What ``keyDownDispatchBegan(_:timestamp:)`` returned.
    func keyDownDispatchEnded(restoring outer: KeyDown?) {
        keyDown = outer
    }

    /// Runs `body`, the input method call for `event`, between the slot's `textInputStart` and `textInputEnd` when
    /// `event` is the key down being dispatched; otherwise only runs it.
    ///
    /// - Parameters:
    ///   - event: The key down the call interprets (the event the view got).
    ///   - body: The `interpretKeyEvents` call (or the text view's `super.keyDown`).
    // perf-hot: 0.1us key-dispatch
    public func interpreting(_ event: NSEvent, _ body: () -> Void) {
        guard let keyDown, keyDown.timestamp == event.timestamp, !isInterpreting else { return body() }
        isInterpreting = true
        defer { isInterpreting = false }
        tracker.mark(keyDown.token, .textInputStart)
        body()
        tracker.mark(keyDown.token, .textInputEnd)
    }
}

/// A window that carries the app's text input stage: a text view that has no owner to hand it the stage (a
/// terminal, the omnibar's field editor) reads it from its window when it joins it, never per key. The App's main
/// windows and its browser popup windows carry it; any other window has none, and its views' text input is not
/// timed apart.
///
/// ```swift
/// override func viewDidMoveToWindow() {
///     super.viewDidMoveToWindow()
///     textInputStage = (window as? TextInputStageHosting)?.textInputStage
/// }
/// ```
@MainActor
public protocol TextInputStageHosting: NSWindow {
    /// The app's one text input stage, or nil.
    var textInputStage: TextInputStage? { get }
}
