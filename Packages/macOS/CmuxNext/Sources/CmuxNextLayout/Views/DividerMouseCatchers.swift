public import AppKit
import CmuxNextDesign

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
/// keeps them above page windows with its other app panels. Lives here, not
/// in CmuxNextApp (code-quality.md SW14).
///
/// The panels are a pool that only grows to the most dividers shown at once.
/// A panel with no area to cover is parked (transparent, 1 pt, ignores the
/// mouse) and stays a child window; nothing on the workspace switch path
/// creates, removes or orders out a window. Creating a panel (a WindowServer
/// window) and ordering one out on every switch took 2-3.5 s of the main
/// thread in the GUI fuzzer (perf100, seeds 4 and 5), because AppKit's child
/// ordering walks the parent's whole window group per operation.
@MainActor
public final class DividerMouseCatchers {
    private unowned let window: NSWindow
    /// Slot i covers the i-th wanted area; slots past the areas are parked.
    private var panels: [DividerMousePanel] = []
    /// Called with (divider id, hovered) for the divider's hover line.
    public var onHover: ((String, Bool) -> Void)?

    public init(window: NSWindow) {
        self.window = window
    }

    /// Window numbers of the panels covering an area: they pass divider hover through.
    public var windowNumbers: Set<Int> { Set(panels.filter { $0.areaID != nil && $0.isVisible }.map(\.windowNumber)) }

    /// Frames of the panels covering an area, in window coordinates (`debug.layers`).
    public var framesInWindow: [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for panel in panels where panel.parent === window {
            if let id = panel.areaID { frames[id] = window.convertFromScreen(panel.frame) }
        }
        return frames
    }

    /// Panels made so far (`debug.layers`): the most dividers shown at once.
    public var poolSize: Int { panels.count }

    /// Shows one panel per area (window coordinates), or none when `active`
    /// is false (no page window is visible).
    public func update(_ areas: [LayoutMouseArea], active: Bool) {
        let wanted = active && window.isVisible ? areas : []
        for (index, area) in wanted.enumerated() {
            if index == panels.count { panels.append(makePanel()) }
            let panel = panels[index]
            if panel.areaID != area.id { panel.release() }
            panel.areaID = area.id
            panel.catcher.resizesColumns = area.resizesColumns
            let frame = window.convertToScreen(area.rect)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            if panel.alphaValue != 1 { panel.alphaValue = 1 }
            // Only the first time, or after the window took it back: never on a switch.
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        }
        for panel in panels.dropFirst(wanted.count) { park(panel) }
    }

    /// The window is closing: the panels leave it for good.
    public func teardown() {
        for panel in panels {
            panel.release()
            if panel.parent === window { window.removeChildWindow(panel) }
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    /// Covers nothing and takes no mouse; stays a child window (no ordering).
    /// A parked panel never starts a `WindowOverlayHost.reassertOrder`; a reorder that runs moves it too.
    private func park(_ panel: DividerMousePanel) {
        if panel.areaID != nil || !panel.ignoresMouseEvents || panel.alphaValue != 0 {
            panel.release()
            panel.areaID = nil
            panel.ignoresMouseEvents = true
            panel.alphaValue = 0
        }
        let corner = window.convertToScreen(CGRect(x: 0, y: 0, width: 1, height: 1))
        if panel.frame != corner { panel.setFrame(corner, display: false) }
    }

    private func makePanel() -> DividerMousePanel {
        let panel = DividerMousePanel()
        panel.catcher.onHover = { [weak self, weak panel] hovered in
            guard let self, let id = panel?.areaID else { return }
            self.onHover?(id, hovered)
        }
        return panel
    }
}

/// A transparent panel that takes the mouse over a divider's hit area.
final class DividerMousePanel: NSPanel, ParkablePanel {
    let catcher = DividerMouseCatcherView()
    /// The divider this panel covers now; nil while parked.
    var areaID: String?
    var isParked: Bool { areaID == nil && ignoresMouseEvents }

    /// Ends a hover the pointer would otherwise never leave (the panel moves
    /// away from under it): the divider's hover line goes out.
    func release() {
        catcher.endHover()
    }

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
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor {
        if #available(macOS 15, *) { return resizesColumns ? .columnResize : .rowResize }
        return resizesColumns ? .resizeLeftRight : .resizeUpDown
    }

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
        isHovered = true
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) { endHover() }

    func endHover() {
        guard isHovered else { return }
        isHovered = false
        onHover?(false)
    }

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
