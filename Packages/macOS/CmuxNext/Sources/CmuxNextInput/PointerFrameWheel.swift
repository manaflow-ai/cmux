public import AppKit
public import CmuxNextInputCore
public import CmuxNextWakeups

/// A view's wheel and trackpad scrolls on its window's ``FrameInputCoalescer``: the first scroll of a
/// frame interval scrolls in its own turn, the rest of the interval once at the frame with their deltas
/// summed, as Chromium queues wheels on the main thread (`third_party/blink/renderer/platform/widget/input/
/// main_thread_event_queue.cc`). Only one scroll phase merges (`third_party/blink/common/input/
/// web_mouse_wheel_event.cc` `CanCoalesce`): a gesture's start, its end and momentum's start and end are
/// deliveries of their own. With no ``frames`` (the feature off) or no window, each event scrolls at once.
///
/// A press is discrete: the view calls ``flush()`` before it acts on one, so it sees the scrolls before it.
/// A delivery after the view left its window scrolls nothing.
///
/// ```swift
/// lazy var wheel = PointerFrameWheel(owner: "SavedGroupsBarView.wheel", view: self) { [weak self] scroll in
///     self?.scroll(by: -scroll.delta.dx)
/// }
/// override func scrollWheel(with event: NSEvent) { wheel.scrolled(event) }
/// override func mouseDown(with event: NSEvent) { wheel.flush(); press(at: event.locationInWindow) }
/// ```
@MainActor
public final class PointerFrameWheel {
    /// One delivery: one scroll event, or the events of one phase in a frame interval.
    public struct Scroll: Sendable {
        /// The summed `scrollingDeltaX` and `scrollingDeltaY` (points for a trackpad, lines for a wheel).
        public var delta: CGVector
        /// A trackpad's or Magic Mouse's point deltas, not a wheel's lines.
        public var isPrecise: Bool
        public var phase: InputScrollPhase
        /// The pointer at the latest event, in its window's coordinates.
        public var location: CGPoint

        public init(delta: CGVector, isPrecise: Bool, phase: InputScrollPhase, location: CGPoint) {
            self.delta = delta
            self.isPrecise = isPrecise
            self.phase = phase
            self.location = location
        }

        /// The scroll of `event`.
        public init(_ event: NSEvent) {
            self.init(delta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY), isPrecise: event.hasPreciseScrollingDeltas,
                      phase: InputEventRecord.scrollPhase(of: event), location: event.locationInWindow)
        }

        init(_ input: PointerCoalescedInput) {
            self.init(delta: CGVector(dx: input.scrollDelta.x, dy: input.scrollDelta.y), isPrecise: input.latest.hasPreciseScrollingDeltas,
                      phase: input.latest.scrollPhase, location: CGPoint(x: input.latest.location.x, y: input.latest.location.y))
        }

        /// A mouse wheel's notch: no gesture around it, so each one is over when it is delivered.
        public var isNotch: Bool {
            if case .none = phase { true } else { false }
        }

        /// The gesture is over for now: the fingers lifted (momentum may follow), it was cancelled, or
        /// the momentum ended. A wheel's notch has no gesture and never ends one.
        public var endsGesture: Bool {
            switch phase {
            case .ended, .cancelled, .momentumEnded: true
            case .none, .mayBegin, .began, .changed, .momentum: false
            }
        }
    }

    /// The windows' coalescers (the App injects them); nil: each event scrolls at once. A change drops
    /// the pending scrolls.
    public var frames: FrameInputCoalescers? {
        didSet { if frames !== oldValue { cancel() } }
    }
    private let owner: String
    private weak var view: NSView?
    private let scroll: @MainActor (Scroll) -> Void
    private var consumer: PointerFrameConsumer?
    /// The window `consumer` posts to.
    private weak var consumerWindow: NSWindow?

    /// - Parameters:
    ///   - owner: The consumer's name in the window's coalescer (debug.input).
    ///   - view: The view the scrolls are for: a delivery scrolls only while it is still in the event's window.
    ///   - scroll: Applies one delivery.
    public init(owner: String, view: NSView, frames: FrameInputCoalescers? = nil, scroll: @escaping @MainActor (Scroll) -> Void) {
        self.owner = owner
        self.view = view
        self.frames = frames
        self.scroll = scroll
    }

    /// A scroll event in the view: it scrolls now on its frame interval's leading edge, or at the frame.
    public func scrolled(_ event: NSEvent) {
        if let consumer = consumer(for: view?.window), consumer.post(event) { return }
        scroll(Scroll(event))
    }

    /// The pending scrolls apply now (a press comes next).
    public func flush() { consumer?.flush() }

    /// The view's scrolls are waiting for the frame (debug and tests).
    public var hasPending: Bool { consumer?.hasPending ?? false }

    /// Drops the pending scrolls and lets go of the window's consumer.
    public func cancel() {
        consumer?.cancel()
        consumer = nil
        consumerWindow = nil
    }

    /// The consumer on `window`'s coalescer, made on its first scroll there; nil without frames or a window.
    private func consumer(for window: NSWindow?) -> PointerFrameConsumer? {
        guard let window, let frames else { return nil }
        if let consumer, consumerWindow === window { return consumer }
        cancel()
        let made = frames.coalescer(for: window).consumer(owner: owner) { [weak self, weak window] input in
            guard let self, let window, view?.window === window else { return }
            scroll(Scroll(input))
        }
        consumer = made
        consumerWindow = window
        return made
    }
}
