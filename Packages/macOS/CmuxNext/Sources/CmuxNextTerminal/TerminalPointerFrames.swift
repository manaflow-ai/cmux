import AppKit
import CmuxNextInput
import CmuxNextInputCore
import CmuxNextWakeups

/// One terminal view's pointer input on its window's ``FrameInputCoalescer`` (feature
/// `terminalPointerFrames`), as Chromium aligns mouse moves and wheels to the frame
/// (`third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc`, `IsRafAlignedEvent`):
///
/// - Moves and drags reach Ghostty (`ghostty_surface_mouse_pos`) on a frame interval's first event and
///   once more at its frame, at the latest point; link hover follows each delivery.
/// - A trackpad scroll while the program has the mouse goes the same way, its deltas summed per scroll
///   phase into one `ghostty_surface_mouse_scroll`: each call takes the terminal's lock and writes
///   mouse reports. A scroll through the scrollback, and a wheel's line scroll, go at once.
/// - A button, a scroll that goes at once, and entering or leaving the view deliver what is pending
///   first (Chromium's `ShouldFlushQueue`), so Ghostty sees every event in the order it came.
///
/// The view makes it only while the feature is on, and drops what is pending when it leaves its window.
@MainActor
final class TerminalPointerFrames {
    private let coalescers: FrameInputCoalescers
    private let deliver: @MainActor (PointerCoalescedInput) -> Void
    /// The window ``consumer`` posts to.
    private weak var window: NSWindow?
    private var consumer: PointerFrameConsumer?

    init(coalescers: FrameInputCoalescers, deliver: @escaping @MainActor (PointerCoalescedInput) -> Void) {
        self.coalescers = coalescers
        self.deliver = deliver
    }

    /// Posts a move, drag or scroll to `window`'s coalescer, which delivers it now or at the frame.
    /// False when nothing was posted (no window): the caller sends the event itself.
    func post(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return windowConsumer(window).post(event)
    }

    /// Delivers what is pending now.
    func flush() {
        consumer?.flush()
    }

    /// Drops what is pending: the view left its window.
    func cancel() {
        consumer?.cancel()
        consumer = nil
        window = nil
    }

    /// Input of this view is waiting for the frame (tests).
    var hasPending: Bool { consumer?.hasPending ?? false }

    /// The most deliveries this view got in one frame interval (tests: at most 2).
    var maxDeliveriesPerFrame: Int { consumer?.maxDeliveriesPerFrame ?? 0 }

    private func windowConsumer(_ window: NSWindow) -> PointerFrameConsumer {
        if let consumer, self.window === window { return consumer }
        consumer?.cancel()
        let made = coalescers.coalescer(for: window).consumer(owner: "TerminalSurfaceView", deliver: deliver)
        self.window = window
        consumer = made
        return made
    }
}
