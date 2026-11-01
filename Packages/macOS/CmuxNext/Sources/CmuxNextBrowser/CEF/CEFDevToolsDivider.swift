import AppKit
import CmuxNextDesign

/// The line between a CEF page and its docked DevTools. Drag it to resize
/// (the page and DevTools windows punch a hole for its grab area, so the
/// mouse reaches it over both); its menu moves DevTools like the dock
/// side items of the DevTools menu.
final class CEFDevToolsDivider: NSView {
    weak var devTools: CEFDevToolsController?
    private var dragging = false { didSet { updateGlow() } }
    private var hovered = false { didSet { updateGlow() } }
    /// The accent band over the line while hovered or dragged (`DividerGlowBand`); it stays
    /// inside this view, which the page and DevTools windows leave uncovered.
    let glow = DividerGlowBand()
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(glow.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The page and DevTools are their own windows and take key when used,
    /// so the drag's first click often lands while cmux's window is not key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let devTools else { return }
        performWithTheme { Borders.color(Palette.separator) }.setFill()
        let line = devTools.layout.dock.isSide
            ? NSRect(x: bounds.midX - CEFDevToolsLayout.lineThickness / 2, y: 0, width: CEFDevToolsLayout.lineThickness, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - CEFDevToolsLayout.lineThickness / 2, width: bounds.width, height: CEFDevToolsLayout.lineThickness)
        line.fill()
    }

    override func layout() {
        super.layout()
        let side = devTools?.layout.dock.isSide ?? true
        let t = CEFDevToolsLayout.lineThickness
        let line = side
            ? NSRect(x: bounds.midX - t / 2, y: 0, width: t, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - t / 2, width: bounds.width, height: t)
        glow.place(along: line, vertical: side)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        glow.applyTheme(self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glow.applyTheme(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    /// Removed mid-hover or mid-drag: no exit or release arrives, so the band goes out with it.
    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        if newSuperview == nil {
            dragging = false
            hovered = false
        }
    }

    private func updateGlow() {
        glow.set(dragging ? .dragging : hovered ? .hovered : .rest)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: devTools?.layout.dock.isSide == true ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let devTools, let container = superview else { return }
        devTools.dragDivider(to: container.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        devTools?.rememberLayout()
    }

    /// The dock side choices (CEF runs DevTools with docking off, so its
    /// own three-dot menu has none).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tab = devTools?.tab else { return nil }
        let menu = NSMenu()
        for (title, dock) in [(Strings.devToolsDockLeft, BrowserDevToolsDock.left), (Strings.devToolsDockBottom, .bottom),
                              (Strings.devToolsDockRight, .right), (Strings.devToolsUndock, .window)] {
            let item = NSMenuItem(title: title, action: #selector(dockItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dock.rawValue
            item.state = tab.devTools.dock == dock ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: Strings.devToolsClose, action: #selector(closeItem(_:)), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func dockItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let dock = BrowserDevToolsDock(rawValue: raw) else { return }
        devTools?.perform(.dock(dock))
    }

    @objc private func closeItem(_ sender: NSMenuItem) {
        devTools?.perform(.close)
    }
}
