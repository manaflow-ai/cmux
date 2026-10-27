import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups

/// The content of ``BrowserSectionOverlay``: dims the page outside the
/// dragged rect, outlines it, and shows how to use it until a drag starts.
final class BrowserSectionOverlayView: NSView {
    /// Called once: the selection on mouse-up, or nil on Esc or a click.
    var onFinish: ((BrowserSectionSelection?) -> Void)?
    private(set) var selection: BrowserSectionSelection
    /// The windows' frame-aligned pointer input (feature `pointerFrameDrags`): the rect follows a frame
    /// interval's first drag event at once and the rest once at its frame, at the latest point, as
    /// Chromium delivers rAF-aligned moves (main_thread_event_queue.cc). Nil: every drag event moves it.
    private let pointerFrames: FrameInputCoalescers?
    /// This drag's consumer of the panel's coalescer, from mouse-down to mouse-up.
    private var frameDrag: PointerFrameConsumer?
    private let hint = NSTextField(labelWithString: String(
        localized: "browser.screenshotSection.hint", defaultValue: "Drag to capture a section. Press Esc to cancel.",
        bundle: .module))

    init(size: CGSize, pointerFrames: FrameInputCoalescers? = nil) {
        selection = BrowserSectionSelection(bounds: CGRect(origin: .zero, size: size))
        self.pointerFrames = pointerFrames
        super.init(frame: CGRect(origin: .zero, size: size))
        autoresizingMask = [.width, .height]
        hint.font = .systemFont(ofSize: TypeScale.body, weight: TypeScale.emphasis)
        hint.textColor = .white
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel(hint.stringValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        selection.begin(at: convert(event.locationInWindow, from: nil))
        hint.isHidden = true
        needsDisplay = true
        frameDrag?.cancel()
        frameDrag = window.flatMap { pointerFrames?.coalescer(for: $0) }?.consumer(owner: "BrowserSectionOverlay") { [weak self] input in
            self?.drag(to: CGPoint(x: input.latest.location.x, y: input.latest.location.y))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let frameDrag, frameDrag.post(event) { return }
        drag(to: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        // The frame's pending point lands before the release (Chromium's ShouldFlushQueue).
        frameDrag?.flush()
        frameDrag = nil
        drag(to: event.locationInWindow)
        finish(selection.rect == nil ? nil : selection)
    }

    /// The rect's moving corner goes to `windowPoint`; AppKit draws it in the next frame.
    private func drag(to windowPoint: CGPoint) {
        selection.drag(to: convert(windowPoint, from: nil))
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        finish(nil)
    }

    override func keyDown(with event: NSEvent) {
        // Esc arrives as cancelOperation through interpretKeyEvents.
        interpretKeyEvents([event])
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let rect = selection.rect else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    private func finish(_ selection: BrowserSectionSelection?) {
        // Esc or the panel losing key mid-drag: nothing pending may move the rect after the answer.
        frameDrag?.cancel()
        frameDrag = nil
        let onFinish = self.onFinish
        self.onFinish = nil
        onFinish?(selection)
    }
}
