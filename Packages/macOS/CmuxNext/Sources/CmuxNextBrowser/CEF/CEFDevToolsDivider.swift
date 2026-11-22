import AppKit
import CmuxNextDesign

/// The line between a CEF page and its docked DevTools. Drag it to resize
/// (the page and DevTools windows punch a hole for its grab area, so the
/// mouse reaches it over both); its menu moves DevTools like the dock
/// side items of the DevTools menu.
final class CEFDevToolsDivider: NSView {
    weak var devTools: CEFDevToolsController?
    private var dragging = false

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let devTools else { return }
        Borders.color(NSColor.separatorColor).setFill()
        let line = devTools.layout.dock.isSide
            ? NSRect(x: bounds.midX - CEFDevToolsLayout.lineThickness / 2, y: 0, width: CEFDevToolsLayout.lineThickness, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - CEFDevToolsLayout.lineThickness / 2, width: bounds.width, height: CEFDevToolsLayout.lineThickness)
        line.fill()
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
