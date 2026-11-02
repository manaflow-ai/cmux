import AppKit
import CmuxNextDesign

/// The chat's Session Info, drawn by the App (``AgentPaneSessionInfo``): the shared overlay glass
/// floating over the agent pane at its right, from under the header to the pane's foot (Leo,
/// 2026-10-26: "you still haven't done the full-length thing"). It floats: it never takes a column
/// and never moves the chat's layout; the page supplies the current push or overlay geometry. No close button and no band at its top:
/// its header toggle and Esc close it. Its left edge drags its width.
final class AgentPaneSessionInfoPanel: NSView {
    let store: AgentPaneSessionInfoStore
    private let glass: OverlaySurfaceView
    private let edge = AgentPaneSessionInfoEdge()

    init(store: AgentPaneSessionInfoStore) {
        self.store = store
        let content = AgentPaneSessionInfoContent(store: store)
        glass = Glass.makeOverlayPanel(content: content)
        super.init(frame: .zero)
        glass.translatesAutoresizingMaskIntoConstraints = true
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        edge.autoresizingMask = [.height, .maxXMargin]
        addSubview(edge)
        edge.onDrag = { [weak self] delta, ended in self?.store.drag(by: delta, ended: ended) }
        edge.onDoubleClick = { [weak self] in self?.store.act("width:reset") }
        store.rectForView = { [weak self] view in
            guard let self else { return nil }
            return self.convert(view.bounds, from: view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glass.frame = bounds
        edge.frame = CGRect(x: 0, y: 0, width: AgentPaneSessionInfoEdge.width, height: bounds.height)
        applyHoles()
    }

    /// The page's open popups over the panel, in its coordinates (AgentPaneView+SessionInfo.swift).
    /// The panel draws nothing and takes no clicks in them, so the popup the page draws under it shows
    /// whole and keeps its hover and clicks; with none the panel is untouched.
    var holes: [AgentPaneSessionInfoOverlay] = [] {
        didSet { if holes != oldValue { applyHoles() } }
    }

    private func applyHoles() {
        let cut = holes.filter { $0.rect.intersects(bounds) }
        guard !cut.isEmpty else {
            if layer?.mask != nil { layer?.mask = nil }
            return
        }
        wantsLayer = true
        let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.path = Self.maskPath(bounds: bounds, holes: cut)
        // A mask follows the popup at once: no implicit fade between reports.
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        if layer?.mask !== mask { layer?.mask = mask }
    }

    /// The panel's bounds with each hole (rounded as the popup's corners) left out.
    static func maskPath(bounds: CGRect, holes: [AgentPaneSessionInfoOverlay]) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        for hole in holes {
            let radius = max(0, min(hole.radius, hole.rect.width / 2, hole.rect.height / 2))
            path.addRoundedRect(in: hole.rect, cornerWidth: radius, cornerHeight: radius)
        }
        return path
    }

    /// Whether a point in the panel's coordinates is in a popup's hole.
    func yields(at point: CGPoint) -> Bool { holes.contains { $0.rect.contains(point) } }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A click or hover in a popup's hole goes on to the page under the panel.
        if !holes.isEmpty, yields(at: convert(point, from: superview)) { return nil }
        return super.hitTest(point)
    }

    /// The panel's bounds less the holes, as rects in its coordinates (a Chromium page's uncovered
    /// regions, which take rects only).
    func uncoveredRects() -> [CGRect] {
        holes.reduce([bounds]) { pieces, hole in pieces.flatMap { Self.subtract(hole.rect, from: $0) } }
    }

    /// `rect` less `hole`: up to four rects (the bands above and below it, and beside it between).
    static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(hole)
        guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
            CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
            CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    /// Esc from inside the panel closes it, as the page's did.
    override func cancelOperation(_ sender: Any?) { store.act("close") }
}

/// What the panel draws and how its clicks reach the page.
@MainActor final class AgentPaneSessionInfoStore {
    var info: AgentPaneSessionInfoModel? { didSet { if info != oldValue { redraw() } } }
    var colors = AgentPaneSessionInfoColors() { didSet { if colors != oldValue { redraw() } } }
    /// Points per CSS pixel: the page's zoom.
    var zoom: CGFloat = 1
    /// The width a drag of the left edge gives the panel before the page hears it, CSS pixels.
    var dragWidth: Double?
    /// Sends a row's, a button's or the panel's own action id to the page.
    var send: (String) -> Void = { _ in }
    /// Sends an action with an optional page-coordinate anchor. The legacy callback remains for
    /// callers that do not need a popover anchor.
    var sendWithRect: ((String, CGRect?) -> Void)?
    /// Converts a line or button's local rect to pane coordinates.
    var rectForView: (NSView) -> CGRect? = { _ in nil }
    /// The panel's frame needs laying out again (a drag step).
    var relayout: () -> Void = {}
    /// The content draws the model or the colors again (AgentPaneSessionInfoContent).
    var redraw: () -> Void = {}

    /// The panel's width in CSS pixels: the drag's while one runs, else the page's.
    var width: Double { dragWidth ?? info?.width ?? 0 }

    func act(_ id: String, _ rect: CGRect? = nil) {
        if let sendWithRect { sendWithRect(id, rect) } else { send(id) }
    }

    /// The left edge moved `delta` points (positive: right, narrower); at the end the page keeps the
    /// width (its `INSPECTOR_WIDTH` bounds it).
    func drag(by delta: CGFloat, ended: Bool) {
        guard let info else { return }
        let next = min(560, max(260, (dragWidth ?? info.width) - Double(delta / max(0.25, zoom))))
        dragWidth = next
        relayout()
        guard ended else { return }
        send("width:\(Int(next.rounded()))")
    }

    /// The page answered with its width: the drag is over.
    func update(_ next: AgentPaneSessionInfoModel?) {
        if let next, let dragWidth, abs(next.width - dragWidth) < 1 { self.dragWidth = nil }
        if next == nil { dragWidth = nil }
        info = next
    }
}

/// The pane's theme colors, resolved by the view from its tokens.
struct AgentPaneSessionInfoColors: Equatable {
    var primary = ThemeTokens.unresolved.textPrimary.nsColor
    var secondary = ThemeTokens.unresolved.textSecondary.nsColor
    var tertiary = ThemeTokens.unresolved.textTertiary.nsColor
    var hover = ThemeTokens.unresolved.hoverFill.nsColor
    var separator = ThemeTokens.unresolved.separator.nsColor
    var danger = ThemeTokens.unresolved.danger.nsColor
    var success = ThemeTokens.unresolved.success.nsColor
    var attention = ThemeTokens.unresolved.attention.nsColor
    var accent = ThemeTokens.unresolved.litGlyph.nsColor

    init() {}

    init(_ tokens: ThemeTokens) {
        primary = tokens.textPrimary.nsColor
        secondary = tokens.textSecondary.nsColor
        tertiary = tokens.textTertiary.nsColor
        hover = tokens.hoverFill.nsColor
        separator = Borders.color(tokens.separator.nsColor)
        danger = tokens.danger.nsColor
        success = tokens.success.nsColor
        attention = tokens.attention.nsColor
        accent = tokens.litGlyph.nsColor
    }

    func symbol(_ token: String?, fallback: NSColor) -> NSColor {
        guard let token else { return fallback }
        return color(for: token)
    }

    func color(for token: String) -> NSColor {
        switch token {
        case "red", "danger": danger
        case "green", "success": success
        case "yellow", "orange", "waiting": attention
        case "purple", "cyan", "blue", "accent": accent
        case "pink": NSColor.systemPink
        case "muted", "free": tertiary
        case "buffer": secondary
        case "context0": accent
        case "context1": success
        case "context2": attention
        case "context3": danger
        case "context4": NSColor.systemPurple
        case "context5": NSColor.systemBlue
        default: secondary
        }
    }

    func tone(_ tone: AgentPaneSessionInfoModel.Tone?) -> NSColor {
        switch tone {
        case .failed: danger
        case .waiting: attention
        case .accent: accent
        case .muted, .done: tertiary
        case .running, nil: secondary
        }
    }
}

/// The panel's left edge: a resize cursor and a horizontal drag.
final class AgentPaneSessionInfoEdge: NSView {
    static let width: CGFloat = 6
    var onDrag: ((CGFloat, Bool) -> Void)?
    var onDoubleClick: (() -> Void)?
    private var last: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            last = nil
            onDoubleClick?()
            return
        }
        last = event.locationInWindow.x
    }
    override func mouseDragged(with event: NSEvent) { step(event, ended: false) }
    override func mouseUp(with event: NSEvent) { step(event, ended: true) }

    private func step(_ event: NSEvent, ended: Bool) {
        guard let start = last else { return }
        let x = event.locationInWindow.x
        last = ended ? nil : x
        onDrag?(x - start, ended)
    }
}
