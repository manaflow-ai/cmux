public import AppKit
import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextInputCore
public import CmuxNextWakeups
package import CmuxNextRemoteView

#if DEBUG || CMUX_BENCH_HOOKS
/// Receives the page view's keyboard and pointer events (the remote tab).
@MainActor
public protocol RemoteBrowserEventTarget: AnyObject {
    @discardableResult
    func handleKeyEquivalent(_ event: NSEvent) -> Bool
    func handleKey(_ event: NSEvent)
    func handlePointer(_ event: NSEvent)
    /// One frame delivery of merged moves, drags or mid-gesture scrolls (``RemoteBrowserContentView/pointerFrames``):
    /// the latest point, or the summed scroll. `clickCount` is the press's for a drag, else 0.
    func handlePointerFrame(_ input: PointerCoalescedInput, clickCount: Int)
}

/// The page area of a remote tab: decoded frames at 1:1 device pixels. The
/// browser chrome around it (tab strip, omnibar, find) is the local cmux UI
/// (RT11); only the page is remote. Its events go to `eventTarget`.
///
/// With ``pointerFrames`` (feature `pointerFrameRemoteInput`) moves, drags, mid-gesture scrolls and
/// wheel notches go out at most twice per display frame: a frame interval's first event at once, the rest merged
/// into one delivery at the window's frame (the latest point; scroll deltas summed per phase), as
/// Chromium delivers rAF-aligned input (`third_party/blink/renderer/platform/widget/input/
/// main_thread_event_queue.cc`). Buttons, enter, leave, keys and scroll phase edges flush what waits
/// first (`ShouldFlushQueue`), so the page sees every event in the order it came.
public final class RemoteBrowserContentView: NSView, KeyEquivalentOwningSurface {
    package let video = RemoteVideoView()
    public weak var eventTarget: (any RemoteBrowserEventTarget)?

    /// The windows' frame-aligned pointer input; nil sends every move and scroll at once.
    public var pointerFrames: FrameInputCoalescers? {
        didSet { if pointerFrames !== oldValue { dropFramePointer() } }
    }
    /// This view's consumer of its window's coalescer, made on the first move in a window.
    private var framePointer: PointerFrameConsumer?
    /// The click count of the last button press: a drag carries it, as AppKit's dragged events do.
    private var pressClickCount = 0

    nonisolated public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    /// The page's cursor (`rb.cursor`), shown over the whole page area: set when the pointer enters
    /// (the hover area's `.cursorUpdate`) and when the page changes it under the pointer.
    public var pageCursor: NSCursor = .arrow {
        didSet {
            guard pageCursor !== oldValue else { return }
            if let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) { pageCursor.set() }
        }
    }

    /// The page size in CSS pixels at the window's scale (`rb.screen`).
    public var viewport: RemoteBrowserViewport {
        RemoteBrowserViewport(bounds: bounds.size, backingScale: window?.backingScaleFactor ?? 2)
    }

    /// Called when the viewport may have changed (size or screen scale).
    public var onViewport: ((RemoteBrowserViewport) -> Void)?

    /// Called when the view may have moved on screen or been hidden or
    /// shown: a new frame, window, superview or hidden state. Popup surface
    /// panels follow the page with it.
    public var onPlacementChange: (() -> Void)?

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onViewport?(viewport)
        onPlacementChange?()
    }

    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        onPlacementChange?()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The coalescer is the old window's: what waits there is for a window the view left.
        dropFramePointer()
        onPlacementChange?()
    }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onPlacementChange?()
    }

    // visibility-walk-allow: the hide's own effect, never deferred work (p06 rule 3): the page's popup panels order out with it, and back in on unhide
    public override func viewDidHide() {
        super.viewDidHide()
        onPlacementChange?()
    }

    // visibility-walk-allow: as viewDidHide: the popup panels come back with the page in the unhide's turn
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        onPlacementChange?()
    }

    /// A popup surface's view: it is in a panel that never becomes key, so
    /// the first click acts at once and hover works while the app is active
    /// (not only in the key window).
    package var isSurface = false {
        didSet {
            guard isSurface != oldValue else { return }
            if let hover { removeTrackingArea(hover) }
            hover = nil
            installHover()
        }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isSurface }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onViewport?(viewport)
    }

    public override func cursorUpdate(with event: NSEvent) { pageCursor.set() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        video.autoresizingMask = [.width, .height]
        video.frame = bounds
        addSubview(video)
        installHover()
    }

    /// Why the page is not shown (a refused or lost session), drawn over
    /// the page area; nil while the page streams.
    public private(set) var failureMessage: String?
    private var failureLabel: ThemedLabel?

    /// Shows `message` centered in the page area (nil hides it).
    public func showFailure(_ message: String?) {
        failureMessage = message
        guard let message else {
            failureLabel?.removeFromSuperview()
            failureLabel = nil
            return
        }
        let label = failureLabel ?? ThemedLabel(wrappingLabelWithString: "")
        label.stringValue = message
        label.alignment = .center
        label.ink = .secondary
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.isSelectable = true
        label.focusRingType = .none
        if failureLabel == nil {
            failureLabel = label
            addSubview(label)
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        guard let failureLabel else { return }
        let width = min(max(bounds.width - 48, 0), 480)
        let height = failureLabel.size(forWidth: width).height
        failureLabel.frame = NSRect(x: (bounds.width - width) / 2, y: max((bounds.height - height) / 2, 0), width: width, height: height)
    }

    /// Hover: mouse moves, enter and exit while the pointer is over the
    /// page (CSS `:hover`, tooltips, cursors), with no button down, and the
    /// page's cursor on entry. Covers the visible rect, so it follows every
    /// resize by itself.
    private var hover: NSTrackingArea?

    private func installHover() {
        if let hover, trackingAreas.contains(hover) { return }
        let active: NSTrackingArea.Options = isSurface ? .activeInActiveApp : .activeInKeyWindow
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, active, .inVisibleRect], owner: self, userInfo: nil)
        hover = area
        addTrackingArea(area)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only while the page has keyboard focus: other views keep their chords.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let eventTarget else { return false }
        flushPointer()
        return eventTarget.handleKeyEquivalent(event)
    }

    public override func keyDown(with event: NSEvent) { key(event) }
    public override func keyUp(with event: NSEvent) { key(event) }
    public override func flagsChanged(with event: NSEvent) { key(event) }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(event)
    }

    public override func mouseUp(with event: NSEvent) { discrete(event) }
    // local-monitor-allow: continuous posts to the window's FrameInputCoalescer (pointerFrameRemoteInput) and forwards each event at once without it; a discrete event flushes what waits first, so the page gets every event in order
    public override func mouseDragged(with event: NSEvent) { continuous(event) }
    // local-monitor-allow: as mouseDragged: the window's FrameInputCoalescer, the page's events kept in order
    public override func mouseMoved(with event: NSEvent) { continuous(event) }
    public override func mouseEntered(with event: NSEvent) { discrete(event) }
    public override func mouseExited(with event: NSEvent) { discrete(event) }
    public override func rightMouseDragged(with event: NSEvent) { continuous(event) }
    public override func otherMouseDragged(with event: NSEvent) { continuous(event) }
    /// Wheel and trackpad scrolls go to the page (`wheel`), phases and momentum included: a scroll in
    /// the middle of its gesture, or a wheel notch, waits for the frame; a phase edge goes at once
    /// after what waits.
    // local-monitor-allow: a mid-gesture scroll goes through the window's FrameInputCoalescer (continuous), a phase edge flushes it and goes at once: the page's wheel events keep their order
    public override func scrollWheel(with event: NSEvent) {
        if event.isMergeableScroll { continuous(event) } else { discrete(event) }
    }

    public override func rightMouseDown(with event: NSEvent) { press(event) }
    public override func rightMouseUp(with event: NSEvent) { discrete(event) }
    public override func otherMouseDown(with event: NSEvent) { press(event) }
    public override func otherMouseUp(with event: NSEvent) { discrete(event) }

    // MARK: Frame-aligned pointer input

    /// Delivers the moves and scrolls that wait for the frame now: a discrete event is about to go
    /// to the page, and must not pass them.
    func flushPointer() { framePointer?.flush() }

    private func key(_ event: NSEvent) {
        flushPointer()
        eventTarget?.handleKey(event)
    }

    private func press(_ event: NSEvent) {
        pressClickCount = event.clickCount
        discrete(event)
    }

    private func discrete(_ event: NSEvent) {
        flushPointer()
        eventTarget?.handlePointer(event)
    }

    /// A move, drag, mid-gesture scroll or wheel notch for the page; nothing without a target.
    private func continuous(_ event: NSEvent) { // perf-hot: 2us pointer-coalesce (every move and scroll over a remote page)
        guard eventTarget != nil else { return }
        if let consumer = framePointerConsumer() {
            consumer.post(event)
        } else {
            eventTarget?.handlePointer(event)
        }
    }

    private func framePointerConsumer() -> PointerFrameConsumer? {
        if let framePointer { return framePointer }
        guard let pointerFrames, let window else { return nil }
        let consumer = pointerFrames.coalescer(for: window).consumer(owner: "RemoteBrowserContentView") { [weak self] input in
            guard let self else { return }
            eventTarget?.handlePointerFrame(input, clickCount: input.kind == .drag ? pressClickCount : 0)
        }
        framePointer = consumer
        return consumer
    }

    private func dropFramePointer() {
        framePointer?.cancel()
        framePointer = nil
    }
}
#endif
