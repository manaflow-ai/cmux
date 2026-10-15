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

    /// How far one arrow key or accessibility step moves the divider.
    static let keyboardStep: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("browser.devtools.divider")
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(String(
            localized: "browser.devTools.divider.accessibility",
            defaultValue: "Developer Tools divider",
            bundle: .module
        ))
    }

    // MARK: Accessibility and keyboard

    override func accessibilityValue() -> Any? {
        // The tools' share of the pane, as a whole percentage.
        controller.map { NSNumber(value: Int(($0.layout.devToolsShare * 100).rounded())) }
    }

    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        isSide ? .vertical : .horizontal
    }

    override func accessibilityPerformIncrement() -> Bool {
        controller?.resizeDevTools(by: Self.keyboardStep)
        return controller != nil
    }

    override func accessibilityPerformDecrement() -> Bool {
        controller?.resizeDevTools(by: -Self.keyboardStep)
        return controller != nil
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    /// Arrow keys move the divider: toward the page grows the tools.
    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        let dock = controller.layout.dock
        let step = Self.keyboardStep
        let delta: CGFloat?
        switch (event.specialKey, dock) {
        case (.leftArrow?, .right): delta = step
        case (.rightArrow?, .right): delta = -step
        case (.leftArrow?, .left): delta = -step
        case (.rightArrow?, .left): delta = step
        case (.upArrow?, .bottom): delta = step
        case (.downArrow?, .bottom): delta = -step
        default: delta = nil
        }
        guard let delta else { return super.keyDown(with: event) }
        controller.resizeDevTools(by: delta)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func drawFocusRingMask() {
        bounds.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

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
