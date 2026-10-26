public import AppKit
import CmuxNextInputCore

/// A view's hover moves on its window's ``PointerFrameCoalescer``: the first move of a frame interval
/// hovers in its own turn, the rest of the interval once at the frame, at the latest point, as Chromium
/// delivers rAF-aligned mouse moves (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`).
/// With no ``frames`` (the feature off) or no window, each move hovers at once.
///
/// Enter, exit and a press are discrete: the view calls ``flush()`` before it acts on them, so they see
/// the moves before them (`ShouldFlushQueue`). A move delivered after the view left its window hovers nothing.
///
/// ```swift
/// lazy var hover = PointerFrameHover(owner: "SidebarRailView.hover", view: self) { [weak self] point in
///     self?.hover(atWindowPoint: point)
/// }
/// override func mouseMoved(with event: NSEvent) { hover.moved(event) }
/// override func mouseExited(with event: NSEvent) { hover.flush(); clearHover() }
/// ```
@MainActor
public final class PointerFrameHover {
    /// The windows' coalescers (the App injects them); nil: each move hovers at once. A change drops
    /// the pending moves.
    public var frames: PointerFrameCoalescers? {
        didSet { if frames !== oldValue { cancel() } }
    }
    private let owner: String
    private weak var view: NSView?
    /// Hovers at a point in the view's window coordinates.
    private let hover: @MainActor (CGPoint) -> Void
    private var consumer: PointerFrameConsumer?
    /// The window `consumer` posts to.
    private weak var consumerWindow: NSWindow?

    /// - Parameters:
    ///   - owner: The consumer's name in the window's coalescer (debug.input).
    ///   - view: The view the moves are for: a delivery hovers only while it is still in the move's window.
    ///   - hover: Hovers at a point in window coordinates; the view hit-tests it at delivery, so a view that
    ///     scrolled since the move hit-tests where its content is now.
    public init(owner: String, view: NSView, frames: PointerFrameCoalescers? = nil,
                hover: @escaping @MainActor (CGPoint) -> Void) {
        self.owner = owner
        self.view = view
        self.frames = frames
        self.hover = hover
    }

    /// A pointer move in the view: it hovers now on its frame interval's leading edge, or at the frame.
    public func moved(_ event: NSEvent) {
        if let consumer = consumer(for: view?.window), consumer.post(event) { return }
        hover(event.locationInWindow)
    }

    /// The pending moves hover now (an enter, an exit or a press comes next).
    public func flush() { consumer?.flush() }

    /// The view's moves are waiting for the frame (debug and tests).
    public var hasPending: Bool { consumer?.hasPending ?? false }

    /// The most hovers one frame interval delivered in the current window (debug and tests: at most 2).
    public var maxDeliveriesPerFrame: Int { consumer?.maxDeliveriesPerFrame ?? 0 }

    /// Drops the pending moves and lets go of the window's consumer.
    public func cancel() {
        consumer?.cancel()
        consumer = nil
        consumerWindow = nil
    }

    /// The consumer on `window`'s coalescer, made on its first move there; nil without frames or a window.
    private func consumer(for window: NSWindow?) -> PointerFrameConsumer? {
        guard let window, let frames else { return nil }
        if let consumer, consumerWindow === window { return consumer }
        cancel()
        let made = frames.coalescer(for: window).consumer(owner: owner) { [weak self, weak window] input in
            guard let self, let window, view?.window === window else { return }
            hover(CGPoint(x: input.latest.location.x, y: input.latest.location.y))
        }
        consumer = made
        consumerWindow = window
        return made
    }
}
