import AppKit
import CmuxNextDesign

/// The chat's Session Info, drawn by the App (``AgentPaneSessionInfo``): its content on the pane's
/// own glass, with no card, fill or rounded surface behind it (Leo, 2026-11-01: "why is the
/// background STILL not removed"), at the agent pane's right, from under the header. It is as tall
/// as its content, up to the pane's foot (then its list scrolls), so no empty panel hangs under its
/// last section (Leo, 2026-11-02: "IT IS TAKING THIS STUPID FUCKING SPACE FOR NO REASON"). It floats:
/// it never takes a column and never moves the chat's layout; the page supplies the current push or
/// overlay geometry. Over the chat's column (the page sends `overChat`, or a `foot`) the transcript runs under it,
/// so there, and only there, it lies on the composer's glass (``backing``, the shared overlay glass,
/// solid under Reduce Transparency) so its text never reads through the chat's, as the web panel's
/// `.ui-glass` does over the chat. No close button and no band at its top: its header toggle and Esc
/// close it. Its left edge drags its width.
final class AgentPaneSessionInfoPanel: NSView {
    let store: AgentPaneSessionInfoStore
    private let content: AgentPaneSessionInfoContent
    private let edge = AgentPaneSessionInfoEdge()
    /// The glass under the content while the panel lies over the chat's column; nil over the
    /// pane's empty gutter, where the content stands on the pane itself.
    private(set) var backing: OverlaySurfaceView?

    init(store: AgentPaneSessionInfoStore) {
        self.store = store
        content = AgentPaneSessionInfoContent(store: store)
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        edge.autoresizingMask = [.height, .maxXMargin]
        addSubview(edge)
        let draw = store.redraw
        store.redraw = { [weak self] in
            draw()
            self?.updateBacking()
            self?.applyEdge()
        }
        content.onHeightChange = { [weak store] in store?.relayout() }
        updateBacking()
        applyEdge()
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

    /// The content's height at `width` points: the panel ends after its last section.
    func fittingHeight(forWidth width: CGFloat) -> CGFloat { content.fittingHeight(forWidth: width) }

    /// Whether `info` lies over the chat's column: it says so (`overChat`), or it stops above the
    /// composer (`foot`, all a page that predates `overChat` sends). A short pane's popover lies over
    /// the transcript with no `foot`; with only `foot` read it had no glass, and the transcript and
    /// its sections showed through each other.
    static func liesOverChat(_ info: AgentPaneSessionInfoModel?) -> Bool {
        info?.overChat == true || info?.foot != nil
    }

    /// Over the chat the content lies on the overlay glass; over the gutter, on nothing.
    private func updateBacking() {
        let overChat = Self.liesOverChat(store.info)
        if overChat, backing == nil {
            let glass = Glass.makeOverlayPanel()
            glass.translatesAutoresizingMaskIntoConstraints = true
            glass.autoresizingMask = [.width, .height]
            glass.frame = bounds
            addSubview(glass, positioned: .below, relativeTo: content)
            backing = glass
        } else if !overChat, let glass = backing {
            glass.removeFromSuperview()
            backing = nil
        }
    }

    /// The panel's edge: a hairline in the theme's separator color on the panel's rounded corners, over
    /// the gutter and over the chat alike, with no fill of its own (Leo, 2026-11-03: "maybe it's ok...?
    /// to HAVE NO BACKGROUND FOR THE SESSION INFO / but i think having a border for it might be better").
    /// A layer's border draws over its sublayers, so it shows over the glass under the content too.
    private func applyEdge() {
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = nil
        layer.cornerRadius = Metrics.panelCornerRadius
        layer.borderWidth = 1 / max(window?.backingScaleFactor ?? 2, 1)
        layer.borderColor = store.colors.separator.cgColor
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyEdge()
    }

    override func layout() {
        super.layout()
        backing?.frame = bounds
        content.frame = bounds
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

    /// Whether a point in the panel's coordinates is in a popup's hole (its rounded shape, as the mask).
    func yields(at point: CGPoint) -> Bool {
        holes.contains { hole in
            guard hole.rect.contains(point) else { return false }
            let radius = max(0, min(hole.radius, hole.rect.width / 2, hole.rect.height / 2))
            return CGPath(roundedRect: hole.rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                .contains(point)
        }
    }

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

    // A click anywhere in the panel gives it the keyboard, as a click in the page's panel focused it:
    // Esc then reaches ``cancelOperation(_:)`` instead of the page, whose focus stayed where it was
    // (the composer, say) and whose own Esc handler only closes the panel from its toggle.
    // The panel draws no focus ring (no ring mask); a line or button keeps its own when it takes focus.
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { takeFocus() }

    /// Takes the keyboard unless the panel or one of its views already has it.
    func takeFocus() {
        guard let window else { return }
        if let focused = window.firstResponder as? NSView, focused.isDescendant(of: self) { return }
        window.makeFirstResponder(self)
    }
}

extension NSView {
    /// A press inside native Session Info: the panel takes the keyboard (``AgentPaneSessionInfoPanel/takeFocus()``).
    func focusEnclosingSessionInfoPanel() {
        var view = superview
        while let current = view {
            if let panel = current as? AgentPaneSessionInfoPanel { return panel.takeFocus() }
            view = current.superview
        }
    }
}

/// What the panel draws and how its clicks reach the page.
@MainActor final class AgentPaneSessionInfoStore {
    var info: AgentPaneSessionInfoModel? { didSet { if info != oldValue { redraw() } } }
    var colors = AgentPaneSessionInfoColors() { didSet { if colors != oldValue { redraw() } } }
    /// Points per CSS pixel: the page's zoom.
    var zoom: CGFloat = 1
    /// The width a drag of the left edge gives the panel before the page hears it, CSS pixels.
    var dragWidth: Double?
    /// The drag ended and the page has not answered yet: its next width is the one to draw.
    private var dragSent = false
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
        dragSent = true
        send("width:\(Int(next.rounded()))")
    }

    /// The page answered with its width: the drag is over. After the drag ended the page's width is
    /// the one drawn even where it differs from the drag's (a pushed panel the pane narrows below the
    /// drag's 260px, cmuxterm-hq#6137), so the panel's frame is the room the page keeps for it.
    func update(_ next: AgentPaneSessionInfoModel?) {
        if let next, let dragWidth, dragSent || abs(next.width - dragWidth) < 1 {
            self.dragWidth = nil
            dragSent = false
        }
        if next == nil {
            dragWidth = nil
            dragSent = false
        }
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
    var identities: [NSColor] = []

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
        identities = (0..<5).compactMap { AgentIdentityTone.rgb($0, tokens: tokens)?.nsColor }
    }

    func identity(_ tone: Int?) -> NSColor? {
        guard let tone, identities.indices.contains(tone) else { return nil }
        return identities[tone]
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
        focusEnclosingSessionInfoPanel()
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
