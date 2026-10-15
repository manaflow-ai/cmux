import AppKit

/// The line between a page and its docked DevTools. Drag it to resize; its menu moves the tools
/// between dock sides and a window, like Chrome's DevTools dock-side control (CEF runs DevTools
/// with its own docking off, so the frontend menu has no dock choices of its own).
///
/// It draws a line as thick as the pane dividers (``BrowserDevToolsLayout/lineThickness``) in
/// the system separator color and takes the mouse ``BrowserDevToolsLayout/grabOutset`` points
/// past it on each side (holes in the engine's page windows let the mouse reach it).
final class BrowserDevToolsDividerView: NSView {
    weak var controller: BrowserDevToolsPaneController?
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("browser.devtools.divider")
        setAccessibilityRole(.splitter)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The page and the tools take key when used, so a drag's first click often lands while the
    /// cmux window is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isSide: Bool { controller?.layout.dock.isSide == true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let thickness = controller?.layout.lineThickness ?? BrowserDevToolsLayout.defaultLineThickness
        let line = isSide
            ? NSRect(x: bounds.midX - thickness / 2, y: 0, width: thickness, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - thickness / 2, width: bounds.width, height: thickness)
        line.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isSide ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let controller, let pane = superview else { return }
        controller.dragDivider(to: pane.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        controller?.finishDividerDrag()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        return BrowserDevToolsDockMenu(controller: controller).makeMenu()
    }
}
