public import AppKit
public import CmuxNextInputCore

/// The text input part of a key down's dispatch (p04-input-101): the input method server round trip that
/// `interpretKeyEvents` (or an `NSTextView`'s key handling) makes, stamped as the key's `textInputStart` and
/// `textInputEnd` so a Japanese or Korean input source's time shows apart from cmux's own dispatch.
///
/// Chromium sends a key down through `interpretKeyEvents` the same way before it forwards it to the renderer
/// (`-[RenderWidgetHostViewCocoa keyEvent:wasKeyEquivalent:]`, content/app_shim_remote_cocoa/
/// render_widget_host_view_cocoa.mm); its `EventMetrics` has no stage for that call, so these two are cmux's.
///
/// ``InputLatencyDispatch`` gives the stage the slot of the key down it dispatches, and takes it back when that
/// dispatch returns. A text view runs its input method call in ``interpreting(_:)``: with a key slot open it reads
/// the clock once before and once after (two clock reads, no allocation); with none (a key up, an untracked or
/// automation key routed around `sendEvent`, a full slot table) it only runs the call. A call inside another (a
/// re-sent chord) runs plainly: the outer call's two stamps already cover it.
///
/// ```swift
/// func interpret(_ event: NSEvent) {
///     guard let textInputStage else { return interpretKeyEvents([event]) }
///     textInputStage.interpreting { interpretKeyEvents([event]) }
/// }
/// ```
@MainActor
public final class TextInputStage {
    private let tracker: InputLatencyTracker
    /// The slot of the key down being dispatched, or nil.
    public private(set) var keyDown: InputLatencyToken?
    /// Whether an ``interpreting(_:)`` call is running.
    private var isInterpreting = false

    /// - Parameter tracker: The tracker the key slots are open in.
    public init(tracker: InputLatencyTracker) {
        self.tracker = tracker
    }

    /// The dispatch of the key down whose slot is `token` began: its text input call stamps that slot.
    ///
    /// - Parameter token: The key down's slot.
    /// - Returns: The slot of the key down whose dispatch this one runs inside, or nil; give it back to
    ///   ``keyDownDispatchEnded(restoring:)``.
    func keyDownDispatchBegan(_ token: InputLatencyToken) -> InputLatencyToken? {
        let outer = keyDown
        keyDown = token
        return outer
    }

    /// The key down's dispatch returned: the stage goes back to the slot of the dispatch it ran inside.
    ///
    /// - Parameter outer: What ``keyDownDispatchBegan(_:)`` returned.
    func keyDownDispatchEnded(restoring outer: InputLatencyToken?) {
        keyDown = outer
    }

    /// Runs `body`, the input method call of the key down being dispatched, between its slot's `textInputStart`
    /// and `textInputEnd`.
    ///
    /// - Parameter body: The `interpretKeyEvents` call (or the text view's `super.keyDown`).
    // perf-hot: 0.1us key-dispatch
    public func interpreting(_ body: () -> Void) {
        guard let keyDown, !isInterpreting else { return body() }
        isInterpreting = true
        defer { isInterpreting = false }
        tracker.mark(keyDown, .textInputStart)
        body()
        tracker.mark(keyDown, .textInputEnd)
    }
}

/// A window that carries the app's text input stage: a text view that has no owner to hand it the stage (a
/// terminal, the omnibar's field editor) reads it from its window when it joins it, never per key. The App's main
/// windows carry it; any other window has none, and its views' text input is not timed apart.
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
