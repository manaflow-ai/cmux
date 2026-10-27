public import AppKit
import CmuxNextInputCore
public import CmuxNextWakeups

/// A window that carries the app's frame-aligned drag input (feature `pointerFrameDrags`): a view whose
/// press drags something (a reorder, a dot, a lifted row) reads the coalescers from its window on the
/// press, through ``PointerFrameDrag``. The App's main windows carry them; any other window has none,
/// and its drags act on every event.
@MainActor
public protocol DragFrameInputHosting: NSWindow {
    /// The windows' coalescers while the feature is on; nil while it is off.
    var dragFrameInput: FrameInputCoalescers? { get }
}

/// A press's drag moves on its window's ``FrameInputCoalescer``: the first drag event of a frame interval
/// moves in its own turn, the rest of the interval once at the frame, at the latest point, as Chromium
/// delivers rAF-aligned moves (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`).
/// With no frames on the window (the feature off) each drag event moves at once.
///
/// The press and the release are discrete: ``began()`` on mouse-down reads the window's frames and
/// drops what an earlier press left; ``ended()`` on mouse-up lands the pending point before the drop
/// (`ShouldFlushQueue`). A move delivered after the view left its window moves nothing.
///
/// ```swift
/// lazy var dragMoves = PointerFrameDrag(owner: "ProfileBarView.dotDrag", view: self) { [weak self] point in
///     self?.dragDot(toWindowPoint: point)
/// }
/// override func mouseDown(with event: NSEvent) { dragMoves.began(); ... }
/// override func mouseDragged(with event: NSEvent) { dragMoves.dragged(event) }
/// override func mouseUp(with event: NSEvent) { dragMoves.ended(); drop() }
/// ```
@MainActor
public final class PointerFrameDrag {
    private let owner: String
    private weak var view: NSView?
    /// Moves the drag to a point in the view's window coordinates.
    private let move: @MainActor (CGPoint) -> Void
    private var consumer: PointerFrameConsumer?
    /// The window `consumer` posts to.
    private weak var consumerWindow: NSWindow?

    /// - Parameters:
    ///   - owner: The consumer's name in the window's coalescer (debug.input).
    ///   - view: The view whose press drags: a delivery moves only while it is still in the press's window.
    ///   - move: Moves the drag to a point in window coordinates.
    public init(owner: String, view: NSView, move: @escaping @MainActor (CGPoint) -> Void) {
        self.owner = owner
        self.view = view
        self.move = move
    }

    /// A press began: its drag events go to the window's coalescer when the window carries one
    /// (``DragFrameInputHosting``), else each moves at once. What an earlier press left is dropped.
    public func began() {
        consumer?.cancel()
        let window = view?.window
        if consumer != nil, consumerWindow === window { return }
        consumer = nil
        consumerWindow = window
        guard let window, let frames = (window as? DragFrameInputHosting)?.dragFrameInput else { return }
        consumer = frames.coalescer(for: window).consumer(owner: owner) { [weak self, weak window] input in
            guard let self, let window, view?.window === window else { return }
            move(CGPoint(x: input.latest.location.x, y: input.latest.location.y))
        }
    }

    /// A drag event of the press: it moves now on its frame interval's leading edge, or at the frame.
    public func dragged(_ event: NSEvent) { // perf-hot: 2us pointer-coalesce (every drag event of a press)
        if let consumer, consumerWindow === view?.window, consumer.post(event) { return }
        move(event.locationInWindow)
    }

    /// The press ended: the pending point moves now, before the drop.
    public func ended() { consumer?.flush() }

    /// The drag was taken back or handed off: its pending point is dropped.
    public func cancel() { consumer?.cancel() }

    /// The drag's moves are waiting for the frame (debug and tests).
    public var hasPending: Bool { consumer?.hasPending ?? false }

    /// The most moves one frame interval delivered for this press's window (debug and tests: at most 2).
    public var maxDeliveriesPerFrame: Int { consumer?.maxDeliveriesPerFrame ?? 0 }
}
