import AppKit

/// A rounded hover fill behind a popup row or footer command: shows `color` while the pointer is
/// over the view. A layer, so a hover costs no draw pass.
class BrowserDownloadsHoverFill: NSView {
    var fill: NSColor = .clear { didSet { applyFill() } }
    /// Runs when the pointer enters (true) or leaves (false).
    var onHover: (Bool) -> Void = { _ in }
    private(set) var isHovered = false { didSet { applyFill() } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit (subclasses add a nonisolated one to cancel their observation).
    nonisolated deinit {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        onHover(hovered)
    }

    private func applyFill() {
        layer?.backgroundColor = isHovered ? fill.cgColor : NSColor.clear.cgColor
    }
}
