import AppKit
import CmuxHomeRender
import CmuxNextDesign

/// Hosts the render core's root layer (flipped: the core lays out top-left)
/// and exposes its rows to accessibility: the rows are layers, so each
/// visible message is an explicit `NSAccessibilityElement` in a list.
final class HomeRowHostView: NSView {
    weak var controller: HomeController?
    private var elements: [NSAccessibilityElement] = []
    /// Messages selected by a drag across rows, top to bottom.
    private(set) var selection: [HomeHit] = []
    private var dragStart: CGPoint?
    let selectionLayer = CAShapeLayer()
    static let dragThreshold: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        selectionLayer.actions = ["path": NSNull(), "fillColor": NSNull()]
        selectionLayer.zPosition = 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if selectionLayer.superlayer == nil { layer?.addSublayer(selectionLayer) }
    }

    override var acceptsFirstResponder: Bool { !selection.isEmpty }

    // MARK: Selection across rows (whole messages)

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        if !selection.isEmpty { select([]) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.y - start.y) > Self.dragThreshold || abs(point.x - start.x) > Self.dragThreshold else { return }
        autoscroll(with: event)
        dragSelect(from: start, to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        if !selection.isEmpty { window?.makeFirstResponder(self) }
    }

    /// Selects every message whose bubble the vertical span from `a` to `b`
    /// meets (viewport points).
    func dragSelect(from a: CGPoint, to b: CGPoint) {
        let rect = CGRect(x: 0, y: min(a.y, b.y), width: bounds.width, height: max(1, abs(b.y - a.y)))
        select(controller?.hits(in: rect) ?? [])
    }

    private func select(_ hits: [HomeHit]) {
        selection = hits
        let path = CGMutablePath()
        for hit in hits { path.addRoundedRect(in: hit.bubble.insetBy(dx: -2, dy: -2), cornerWidth: 17, cornerHeight: 17) }
        selectionLayer.frame = bounds
        selectionLayer.path = path
        performWithTheme { selectionLayer.fillColor = Palette.selectionFill.cgColor }
    }

    /// The selected messages' text, one message per paragraph.
    var selectedText: String { selection.map(\.text).joined(separator: "\n\n") }

    @objc func copy(_ sender: Any?) {
        guard !selection.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }


    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The message a context menu was opened on.
    private(set) var menuHit: HomeHit?

    /// Right-click or Control-click on a bubble: Copy. Actions the local
    /// owner refuses (and tapbacks, which need a message id the transcript
    /// item does not carry yet) are not offered.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return menu(at: point)
    }

    func menu(at point: CGPoint) -> NSMenu? {
        guard let hit = controller?.hit(at: point) else { return nil }
        menuHit = hit
        let menu = NSMenu()
        let copy = NSMenuItem(title: HomeStrings.copyMessage, action: #selector(copyMessage(_:)), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        return menu
    }

    @objc func copyMessage(_ sender: Any?) {
        guard let text = menuHit?.text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func accessibilityChanged() {
        elements = []
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func accessibilityChildren() -> [Any]? {
        if elements.isEmpty, let controller { elements = controller.accessibilityItems().map(element) }
        return elements
    }

    private func element(_ item: HomeAXItem) -> NSAccessibilityElement {
        let e = NSAccessibilityElement()
        e.setAccessibilityParent(self)
        e.setAccessibilityRole(item.role == .textArea ? .textArea : .staticText)
        e.setAccessibilityLabel(item.label)
        e.setAccessibilityValue(item.value)
        e.setAccessibilityIdentifier(item.id)
        let inWindow = convert(item.frame, to: nil)
        e.setAccessibilityFrame(window?.convertToScreen(inWindow) ?? inWindow)
        return e
    }
}

extension HomeRowHostView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selection.isEmpty }
        if item.action == #selector(copyMessage(_:)) { return menuHit != nil }
        return true
    }
}
