import AppKit
import CmuxHomeRender

/// Hosts the render core's root layer (flipped: the core lays out top-left)
/// and exposes its rows to accessibility: the rows are layers, so each
/// visible message is an explicit `NSAccessibilityElement` in a list.
final class HomeRowHostView: NSView {
    weak var controller: HomeController?
    private var elements: [NSAccessibilityElement] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
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
