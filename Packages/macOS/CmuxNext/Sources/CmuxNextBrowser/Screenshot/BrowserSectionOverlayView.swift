import AppKit
import CmuxNextDesign

/// The content of ``BrowserSectionOverlay``: dims the page outside the
/// dragged rect, outlines it, and shows how to use it until a drag starts.
final class BrowserSectionOverlayView: NSView {
    /// Called once: the selection on mouse-up, or nil on Esc or a click.
    var onFinish: ((BrowserSectionSelection?) -> Void)?
    private var selection: BrowserSectionSelection
    private let hint = NSTextField(labelWithString: String(
        localized: "browser.screenshotSection.hint", defaultValue: "Drag to capture a section. Press Esc to cancel.",
        bundle: .module))

    init(size: CGSize) {
        selection = BrowserSectionSelection(bounds: CGRect(origin: .zero, size: size))
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
    }

    override func mouseDragged(with event: NSEvent) {
        selection.drag(to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        selection.drag(to: convert(event.locationInWindow, from: nil))
        finish(selection.rect == nil ? nil : selection)
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
        let onFinish = self.onFinish
        self.onFinish = nil
        onFinish?(selection)
    }
}
