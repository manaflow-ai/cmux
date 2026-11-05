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
@MainActor
public final class DividerMouseCatchers {
    private unowned let window: NSWindow
    private var panels: [String: DividerMousePanel] = [:]
    /// Panels whose divider left (a workspace switch releases one plane and adopts another in the same turn):
    /// still children of the window, parked (no size, no mouse), and reused for the next divider, so a switch moves a
    /// panel and makes no window. At most ``maxSpares``; more leave the window.
    private var spares: [DividerMousePanel] = []
    private static let maxSpares = 8
    /// Called with (divider id, hovered) for the divider's hover line.
    public var onHover: ((String, Bool) -> Void)?
    /// Whether a layout divider drag runs: only then does a pressed panel keep the resize cursor off the panel.
    public var isDividerDragging: () -> Bool = { false }
    /// Panel frame changes and panels made since launch (`debug.layers`): each is a window
    /// server move, so a bench counts them over an action.
    public private(set) var panelUpdates = 0
    /// Panels made since launch: each is a new window in the window server (`debug.layers`, tests).
    public private(set) var panelsMade = 0

    public init(window: NSWindow) {
        self.window = window
    }

    /// Window numbers of the panels shown: they pass divider hover through.
    public var windowNumbers: Set<Int> { Set(panels.values.filter { $0.isVisible && !$0.ignoresMouseEvents }.map(\.windowNumber)) }

    /// Frames of the panels shown, in window coordinates (`debug.layers`).
    public var framesInWindow: [String: CGRect] {
        panels.compactMapValues { $0.parent === window ? window.convertFromScreen($0.frame) : nil }
    }

    /// The frames (window coordinates) of the page windows over the window's content at the last ``update(_:active:)``.
    private var pages: [CGRect] = []

    /// The frames, in window coordinates, of the page windows over `window`'s content: only a divider area one of them
    /// covers needs a panel. The New Tab spare's page waits 100 000 pt outside the window (`PageOffscreenParking`) and
    /// covers nothing (RESIZE VIDEOS Z1: with only that page, every divider had a panel, and each zoom and unzoom landing
    /// of 12 panes parked or made 11 of them, 13 of the landing frame's 14 ms of main thread).
    public static func pageFrames(over window: NSWindow) -> [CGRect] {
        (window.childWindows ?? []).filter { WindowOverlayHost.isPageWindow($0) && $0.isVisible && $0.frame.intersects(window.frame) }
            .map { window.convertFromScreen($0.frame) }
    }

    /// A page window came over the content, left it or moved since the last update (a page shown in a pane, the spare
    /// adopted, a page tab hidden): the window's overlay layer updates the panels again at rest.
    public var pagesMoved: Bool { Self.pageFrames(over: window) != pages }

    /// Shows one panel per area (window coordinates) that a page window over the content covers, or none when
    /// `active` is false (no page window is visible).
    public func update(_ areas: [LayoutMouseArea], active: Bool) {
        pages = Self.pageFrames(over: window)
        let wanted = active && window.isVisible ? areas.filter { area in pages.contains { $0.intersects(area.rect) } } : []
        let ids = Set(wanted.map(\.id))
        for (id, panel) in panels where !ids.contains(id) {
            panels[id] = nil
            park(panel)
        }
        for area in wanted {
            let panel: DividerMousePanel
            if let shown = panels[area.id] {
                panel = shown
            } else if let spare = spares.popLast() {
                panel = spare
                panel.areaID = area.id
                panel.ignoresMouseEvents = false
            } else {
                panelUpdates += 1
                panel = makePanel(id: area.id)
            }
            panels[area.id] = panel
            panel.catcher.resizesColumns = area.resizesColumns
            let frame = window.convertToScreen(area.rect)
            if panel.frame != frame {
                panel.setFrame(frame, display: false)
                panelUpdates += 1
            }
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        }
        // No divider wants the spares now (no page window, or fewer dividers): only the newest stay parked.
        if wanted.isEmpty, !active || !window.isVisible { for panel in spares { remove(panel) }; spares.removeAll() }
        while spares.count > Self.maxSpares { remove(spares.removeFirst()) }
    }

    /// A panel whose divider left: no size and no mouse, still a child of the window, ready for the next divider.
    private func park(_ panel: DividerMousePanel) {
        panel.ignoresMouseEvents = true
        panel.catcher.resetForReuse()
        if panel.frame.size != .zero {
            panel.setFrame(CGRect(origin: panel.frame.origin, size: .zero), display: false)
            panelUpdates += 1
        }
        spares.append(panel)
    }

    private func remove(_ panel: DividerMousePanel) {
        if panel.parent === window { window.removeChildWindow(panel) }
        panel.orderOut(nil)
    }

    public func teardown() {
        update([], active: false)
    }

    private func makePanel(id: String) -> DividerMousePanel {
        panelsMade += 1
        let panel = DividerMousePanel()
        panel.areaID = id
        panel.catcher.onHover = { [weak self, weak panel] hovered in
            guard let panel, !panel.ignoresMouseEvents else { return }
            self?.onHover?(panel.areaID, hovered)
        }
        panel.catcher.isDividerDragging = { [weak self] in self?.isDividerDragging() ?? false }
        return panel
    }
}

/// A transparent panel that takes the mouse over a divider's hit area.
final class DividerMousePanel: NSPanel {
    let catcher = DividerMouseCatcherView()
    /// The divider this panel takes the mouse for now (a parked panel keeps its last one until reused).
    var areaID = ""

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

    /// Whether the pointer is over this catcher now: its panel shows, takes the mouse, and holds
    /// the pointer. A seam for tests, which have no screen pointer.
    lazy var isPointerOver: () -> Bool = { [weak self] in
        guard let self, let panel = self.window, panel.isVisible, panel.alphaValue > 0, !panel.ignoresMouseEvents,
              !self.isHiddenOrHasHiddenAncestor else { return false }
        return self.convert(self.bounds, to: nil).contains(panel.convertPoint(fromScreen: NSEvent.mouseLocation))
    }
    /// The cursor set queued after an enter, while it is pending (tests await it).
    private(set) var pendingCursorSet: Task<Void, Never>?
    /// Between this catcher's enter and its exit.
    private var isEntered = false
    /// Between a press here and its release: the drag's events come here wherever the pointer goes, and this
    /// panel stays where the press found it until the release (`WindowOverlayLayer`, `isInLayoutMotion`).
    private var isPressed = false

    /// Its panel was parked (its divider left): no enter, press or queued cursor carries to the next divider.
    func resetForReuse() {
        pendingCursorSet?.cancel()
        pendingCursorSet = nil
        isEntered = false
        isPressed = false
    }
    /// A press that started a divider drag keeps the resize cursor; one forwarded elsewhere (a panel frozen over a
    /// terminal during a spring) or a drag cancelled with Escape does not.
    var isDividerDragging: () -> Bool = { false }
    private var keepsResizeCursor: Bool { isPressed && isDividerDragging() }

    override func cursorUpdate(with event: NSEvent) { cursor.set() }
    override func mouseEntered(with event: NSEvent) {
        isEntered = true
        cursor.set()
        // A focused page window holds key. When the pointer leaves it straight onto this panel's
        // part outside it (the sidebar's resize band reaches over the sidebar), AppKit puts the
        // arrow back for the key window later in this event's turn, and this panel, never key,
        // gets no cursor update or move after that. Set the cursor once more on the next turn,
        // only if no exit came and the panel still shows under the pointer (a panel parked,
        // hidden or moved meanwhile gets no exit). One-shot: nothing repeats or stays scheduled.
        pendingCursorSet?.cancel()
        pendingCursorSet = Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingCursorSet = nil
            guard !Task.isCancelled, self.isEntered, self.isPointerOver() else { return }
            self.cursor.set()
        }
        onHover?(true)
    }
    override func mouseExited(with event: NSEvent) {
        isEntered = false
        // A drag that carried the pointer past this panel keeps its resize cursor until the release.
        if keepsResizeCursor { cursor.set() }
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        forward(event)
    }
    override func mouseDragged(with event: NSEvent) {
        if keepsResizeCursor, !isEntered { cursor.set() }
        forward(event)
    }
    override func mouseUp(with event: NSEvent) {
        isPressed = false
        forward(event)
    }
    override func rightMouseDown(with event: NSEvent) { forward(event) }
    override func rightMouseUp(with event: NSEvent) { forward(event) }
    override func otherMouseDown(with event: NSEvent) { forward(event) }
    override func otherMouseUp(with event: NSEvent) { forward(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let parent = window?.parent, let content = parent.contentView else { return }
        let point = content.convert(parent.convertPoint(fromScreen: screenPoint(of: event)), from: nil)
        content.hitTest(point)?.scrollWheel(with: event)
    }

    /// The event's screen point. The pointer leaves the panel while a divider drags, so
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

#if DEBUG || CMUX_BENCH_HOOKS
extension DividerMousePanel: LayoutPassRoleNaming {
    /// The divider it takes the mouse for (a parked spare keeps its last one).
    var layoutPassRole: String { "divider catcher \(areaID)" }
}
#endif
