public import AppKit
import CmuxNextDesign

/// A window's Chief panel on screen (``ChiefPanel``, user 2026-11-06): a slim bar (the Chief's name, Dock or Float,
/// Hide) over the Chief chat it holds, on the overlay glass. Floating, it has rounded corners and a shadow, its bar
/// drags it and its rim resizes it; docked, it draws square at its edge. It holds the Chief's own view, which the
/// window lends it from Home's Chief pane while another workspace shows (``hold(_:)``, ``release()``), so the draft,
/// scroll and selection are the ones Home shows.
///
/// ```swift
/// let panel = ChiefPanelView(title: "Chief", actions: .init(toggleDock: dock, hide: hide, moved: save))
/// panel.hold(chiefView)
/// let stage = panel.place(window.chiefPanel, in: host.bounds, gap: 6) // the stage's area (y runs down)
/// ```
@MainActor
public final class ChiefPanelView: NSView {
    /// What the bar's buttons and the hand moves ask of the window.
    public struct Actions {
        /// Dock (floating) or Float (docked).
        public var toggleDock: @MainActor () -> Void
        /// Hide.
        public var hide: @MainActor () -> Void
        /// A drag or a resize ended at this frame, in the superview's coordinates (y up).
        public var moved: @MainActor (NSRect) -> Void
        /// Stop the Chief's answer (Esc while it answers).
        public var stop: @MainActor () -> Void

        /// - Parameters:
        ///   - toggleDock: Dock or Float.
        ///   - hide: Hide.
        ///   - moved: A drag or resize ended at this frame.
        ///   - stop: Stop the Chief's answer; nothing by default.
        public init(toggleDock: @escaping @MainActor () -> Void, hide: @escaping @MainActor () -> Void,
                    moved: @escaping @MainActor (NSRect) -> Void, stop: @escaping @MainActor () -> Void = {}) {
            self.toggleDock = toggleDock
            self.hide = hide
            self.moved = moved
            self.stop = stop
        }
    }

    /// The bar's height.
    public static let barHeight: CGFloat = 30
    /// How far in from a floating panel's edge a press resizes it.
    static let resizeBand: CGFloat = 6

    /// The bar's buttons and the hand moves.
    public var actions: Actions
    /// Whether the held Chief is answering (``ChiefPanelContent``): Esc then stops it, as in Home, instead of hiding
    /// the panel.
    public var chiefIsAnswering: Bool { (chief as? any ChiefPanelContent)?.chiefIsAnswering == true }
    /// Floating (corners, shadow, drag, resize) or docked (square).
    public private(set) var floating = true
    /// The Chief view this panel shows now; nil while it is in Home's pane.
    public private(set) weak var chief: NSView?

    private let backdrop = Glass.makeOverlayPanel(cornerRadius: Metrics.surfaceCornerRadius, interactive: true)
    private let bar = NSView()
    private let title: NSTextField
    private let dockButton = NSButton()
    private let hideButton = NSButton()
    private let body = NSView()
    private var press: (start: NSPoint, frame: NSRect, edges: Set<NSRectEdge>)?

    /// - Parameters:
    ///   - title: The bar's name of the Chief.
    ///   - actions: The bar's buttons and the hand moves.
    public init(title: String, actions: Actions) {
        self.title = NSTextField(labelWithString: title)
        self.actions = actions
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "layout.chiefPanel", defaultValue: "Chief panel", bundle: .module))
        setAccessibilityIdentifier("window.chiefPanel")
        backdrop.translatesAutoresizingMaskIntoConstraints = true
        backdrop.autoresizingMask = [.width, .height]
        self.title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        self.title.textColor = .secondaryLabelColor
        for (button, id) in [(dockButton, "window.chiefPanel.dock"), (hideButton, "window.chiefPanel.hide")] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.setAccessibilityIdentifier(id)
            button.target = self
        }
        dockButton.action = #selector(toggleDockPressed)
        hideButton.action = #selector(hidePressed)
        let hide = String(localized: "layout.chiefPanel.hide", defaultValue: "Hide the Chief", bundle: .module)
        hideButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: hide)
        hideButton.toolTip = hide
        for view in [self.title, dockButton, hideButton] { bar.addSubview(view) }
        addSubview(backdrop)
        addSubview(body)
        addSubview(bar)
        setFloating(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }

    /// Floating or docked: the corners, the shadow and the Dock/Float button follow.
    public func setFloating(_ floating: Bool) {
        self.floating = floating
        applyDockedWorkspaceChrome(floating: floating)
        layer?.masksToBounds = false
        backdrop.cornerRadius = floating ? Metrics.surfaceCornerRadius : 0
        body.wantsLayer = true
        body.layer?.cornerRadius = floating ? Metrics.surfaceCornerRadius : 0
        body.layer?.masksToBounds = floating
        let label = floating ? String(localized: "layout.chiefPanel.dock", defaultValue: "Dock the Chief to the Side", bundle: .module)
            : String(localized: "layout.chiefPanel.float", defaultValue: "Float the Chief", bundle: .module)
        dockButton.image = NSImage(systemSymbolName: floating ? "sidebar.left" : "macwindow.on.rectangle", accessibilityDescription: label)
        dockButton.toolTip = label
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }

    /// Takes `view` (the Chief's) into the panel, out of wherever it was; nothing when it is here already.
    public func hold(_ view: NSView) {
        guard view.superview !== body else { return }
        chief = view
        view.removeFromSuperview()
        view.autoresizingMask = [.width, .height]
        view.frame = body.bounds
        body.addSubview(view)
    }

    /// Lets the held view go, for Home's pane to take back; the view it held, nil when none.
    @discardableResult
    public func release() -> NSView? {
        guard let view = chief else { return nil }
        chief = nil
        if view.superview === body { view.removeFromSuperview() }
        return view
    }

    /// The keyboard is in the held Chief.
    public var hasKeys: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// The held Chief's message box (`target`, else the first view in it that takes the keys) takes the keys.
    public func focusChief(_ target: NSView? = nil) {
        guard let chief, let window else { return }
        window.makeFirstResponder(target ?? firstKeyView(in: chief) ?? chief)
    }

    /// Places the panel for `panel` in its superview's `bounds` (y up) and returns the stage's area (y down): all
    /// of it under a floating panel, the rest beside a docked one, `gap` apart.
    public func place(_ panel: ChiefPanel, in bounds: CGRect, gap: CGFloat) -> CGRect {
        var (rect, stage) = panel.split(CGRect(origin: .zero, size: bounds.size))
        switch panel.dockedEdge {
        case .left?: stage = CGRect(x: stage.minX + gap, y: stage.minY, width: max(0, stage.width - gap), height: stage.height)
        case .right?: stage.size.width = max(0, stage.width - gap)
        case .top?: stage = CGRect(x: stage.minX, y: stage.minY + gap, width: stage.width, height: max(0, stage.height - gap))
        case .bottom?: stage.size.height = max(0, stage.height - gap)
        case nil: break
        }
        frame = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height).integral
        window?.invalidateCursorRects(for: self)
        return stage
    }

    /// Whether the panel lies that way from the stage: a docked panel at that edge, a floating one on that side of
    /// its superview's middle. A pane focus move off the stage's edge that way goes into it.
    public func lies(toward direction: LayoutDirection, docked edge: DockEdge?) -> Bool {
        switch (edge, direction) {
        case (.left?, .left), (.right?, .right), (.top?, .up), (.bottom?, .down): return true
        case (.some, _): return false
        case (nil, _):
            guard let host = superview?.bounds else { return false }
            switch direction { // the superview's y runs up
            case .left: return frame.midX < host.midX
            case .right: return frame.midX >= host.midX
            case .up: return frame.midY >= host.midY
            case .down: return frame.midY < host.midY
            }
        }
    }

    override public func layout() {
        super.layout()
        let h = Self.barHeight
        backdrop.frame = bounds
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        let button: CGFloat = 24
        hideButton.frame = NSRect(x: bounds.width - button - 6, y: (h - button) / 2, width: button, height: button)
        dockButton.frame = hideButton.frame.offsetBy(dx: -button - 2, dy: 0)
        title.sizeToFit()
        title.frame.origin = NSPoint(x: 12, y: (h - title.frame.height) / 2)
        body.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        chief?.frame = body.bounds
    }

    @objc private func toggleDockPressed() { actions.toggleDock() }
    @objc private func hidePressed() { actions.hide() }

    // MARK: Moving and resizing (floating only)

    /// The edges a press at `point` (this view's coordinates, y down) resizes, as the superview names them (y up).
    private func resizeEdges(at point: NSPoint) -> Set<NSRectEdge> {
        let b = Self.resizeBand
        var edges = Set<NSRectEdge>()
        if point.x <= b { edges.insert(.minX) }
        if point.x >= bounds.width - b { edges.insert(.maxX) }
        if point.y <= b { edges.insert(.maxY) }
        if point.y >= bounds.height - b { edges.insert(.minY) }
        return edges
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard floating, let superview, frame.contains(point) else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        // The rim's resize band and the bar's empty space are the panel's own: they move or resize it.
        if !resizeEdges(at: local).isEmpty { return self }
        let hit = super.hitTest(point)
        if local.y < Self.barHeight, hit === bar || hit === title { return self }
        return hit
    }

    override public func mouseDown(with event: NSEvent) {
        guard floating, let superview else { return super.mouseDown(with: event) }
        press = (superview.convert(event.locationInWindow, from: nil), frame, resizeEdges(at: convert(event.locationInWindow, from: nil)))
    }

    override public func mouseDragged(with event: NSEvent) {
        guard let press, let superview else { return super.mouseDragged(with: event) }
        let point = superview.convert(event.locationInWindow, from: nil)
        let dx = point.x - press.start.x, dy = point.y - press.start.y
        let start = press.frame, least = ChiefPanelFrame.minimumSize
        var next = start
        if press.edges.isEmpty {
            next.origin = NSPoint(x: start.minX + dx, y: start.minY + dy)
        }
        if press.edges.contains(.minX) { next.origin.x = min(start.maxX - least.width, start.minX + dx); next.size.width = start.maxX - next.minX }
        if press.edges.contains(.maxX) { next.size.width = max(least.width, start.width + dx) }
        if press.edges.contains(.minY) { next.origin.y = min(start.maxY - least.height, start.minY + dy); next.size.height = start.maxY - next.minY }
        if press.edges.contains(.maxY) { next.size.height = max(least.height, start.height + dy) }
        frame = next.integral
    }

    override public func mouseUp(with event: NSEvent) {
        guard press != nil else { return super.mouseUp(with: event) }
        press = nil
        actions.moved(frame)
    }

    override public func resetCursorRects() {
        guard floating else { return }
        let b = Self.resizeBand
        addCursorRect(NSRect(x: 0, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - b, y: 0, width: b, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: b), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - b, width: bounds.width, height: b), cursor: .resizeUpDown)
    }

    // MARK: Esc

    /// Esc while the panel's Chief has the keys: stops the Chief's answer while it answers (as Esc does in Home);
    /// else hides a floating panel.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, hasKeys else {
            return super.performKeyEquivalent(with: event)
        }
        if chiefIsAnswering {
            actions.stop()
            return true
        }
        guard floating else { return super.performKeyEquivalent(with: event) }
        actions.hide()
        return true
    }
}

/// The first view under `view` (itself included) that takes the keys.
@MainActor private func firstKeyView(in view: NSView) -> NSView? {
    if view.acceptsFirstResponder { return view }
    for child in view.subviews { if let found = firstKeyView(in: child) { return found } }
    return nil
}
