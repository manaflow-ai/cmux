import AppKit
import CmuxNextLayout

/// Divider hit areas over Chromium pages.
///
/// A divider's hit area is wider than its line and reaches into the panes
/// next to it. A Chromium page is a child window above the parent, so it
/// would get the mouse there. Masking the page there (an occlusion hole)
/// took a band of the page away on each side of every divider. Instead,
/// while pages are visible, each hit area gets a small transparent panel
/// above the pages that takes the mouse and forwards it to the parent
/// window, where the divider view handles it as before. The page draws
/// edge to edge under it.
///
/// Panels are `NSPanel`s at the overlay's level, so `WindowOverlayLayer`
/// keeps them above page windows with its other app panels.
@MainActor
final class DividerMouseCatchers {
    private unowned let window: NSWindow
    private var panels: [String: DividerMousePanel] = [:]
    /// Called with (divider id, hovered) for the divider's hover line.
    var onHover: ((String, Bool) -> Void)?

    init(window: NSWindow) {
        self.window = window
    }

    /// Frames of the panels shown, in window coordinates (`debug.layers`).
    var framesInWindow: [String: CGRect] {
        panels.compactMapValues { $0.parent === window ? window.convertFromScreen($0.frame) : nil }
    }

    /// Shows one panel per area (window coordinates), or none when `active`
    /// is false (no page window is visible).
    func update(_ areas: [LayoutMouseArea], active: Bool) {
        let wanted = active && window.isVisible ? areas : []
        let ids = Set(wanted.map(\.id))
        for (id, panel) in panels where !ids.contains(id) {
            if panel.parent === window { window.removeChildWindow(panel) }
            panel.orderOut(nil)
            panels[id] = nil
        }
        for area in wanted {
            let panel = panels[area.id] ?? makePanel(id: area.id)
            panels[area.id] = panel
            panel.catcher.resizesColumns = area.resizesColumns
            let frame = window.convertToScreen(area.rect)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        }
    }

    func teardown() {
        update([], active: false)
    }

    private func makePanel(id: String) -> DividerMousePanel {
        let panel = DividerMousePanel()
        panel.catcher.onHover = { [weak self] hovered in self?.onHover?(id, hovered) }
        return panel
    }
}

/// A transparent panel that takes the mouse over a divider's hit area.
final class DividerMousePanel: NSPanel {
    let catcher = DividerMouseCatcherView()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Explicitly false: a clear window would otherwise pass clicks
        // through its transparent pixels.
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]
        catcher.autoresizingMask = [.width, .height]
        contentView = catcher
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Forwards every mouse event to the parent window at the same screen
/// point: `NSWindow.sendEvent` hit-tests the parent's views, so the divider
/// view gets the press and, as the press's view, the drags and the release.
final class DividerMouseCatcherView: NSView {
    var resizesColumns = true {
        didSet { if resizesColumns != oldValue { window?.invalidateCursorRects(for: self) } }
    }
    var onHover: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor { resizesColumns ? .columnResize : .rowResize }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // This panel is never key: track always, or it never sees the pointer.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) {
        cursor.set()
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) { forward(event) }
    override func mouseDragged(with event: NSEvent) { forward(event) }
    override func mouseUp(with event: NSEvent) { forward(event) }
    override func rightMouseDown(with event: NSEvent) { forward(event) }
    override func rightMouseUp(with event: NSEvent) { forward(event) }
    override func otherMouseDown(with event: NSEvent) { forward(event) }
    override func otherMouseUp(with event: NSEvent) { forward(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let parent = window?.parent, let content = parent.contentView else { return }
        let point = content.convert(parent.convertPoint(fromScreen: screenPoint(of: event)), from: nil)
        content.hitTest(point)?.scrollWheel(with: event)
    }

    /// The event's screen point. The panel moves while a divider drags, so
    /// the event's own global location is used, not the panel's frame.
    private func screenPoint(of event: NSEvent) -> NSPoint {
        guard let location = event.cgEvent?.location, let height = NSScreen.screens.first?.frame.height else {
            return window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        }
        return NSPoint(x: location.x, y: height - location.y)
    }

    private func forward(_ event: NSEvent) {
        guard let parent = window?.parent,
              let forwarded = NSEvent.mouseEvent(
                  with: event.type, location: parent.convertPoint(fromScreen: screenPoint(of: event)),
                  modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: parent.windowNumber,
                  context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure
              )
        else { return }
        parent.sendEvent(forwarded)
    }
}
