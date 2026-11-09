public import AppKit
import CmuxNextCompat
public import CmuxNextDesign

/// A window's Chief panel on screen (``ChiefPanel``, user 2026-11-06): the Chief chat it holds, on the overlay glass,
/// in one of the ``ChiefPanelStyle`` looks. Floating, it has rounded corners and a shadow, its grip (the bar, the
/// strip, or the resting shape's left edge) drags it anywhere in the window and its rim resizes it; docked, it draws
/// square at its edge under the bar. The collapsing styles rest small while the keys are elsewhere and grow into the
/// whole chat while the Chief has them. It holds the Chief's own view, which the window lends it from Home's Chief
/// pane while another workspace shows (``hold(_:)``, ``release()``), so the draft, scroll and selection are the ones
/// Home shows.
///
/// ```swift
/// let panel = ChiefPanelView(title: "Chief", actions: .init(toggleDock: dock, hide: hide, moved: save))
/// panel.follow { settings.chiefPanelStyle }
/// panel.hold(chiefView)
/// let stage = panel.place(window.chiefPanel, in: host.bounds, gap: 6) // the stage's area (y runs down)
/// ```
@MainActor
public final class ChiefPanelView: NSView, TitlebarPressDeciding {
    /// What the bar's buttons and the hand moves ask of the window.
    public struct Actions {
        /// Dock (floating) or Float (docked).
        public var toggleDock: @MainActor () -> Void
        /// Hide.
        public var hide: @MainActor () -> Void
        /// A drag or a resize ended: the floating place to keep.
        public var moved: @MainActor (ChiefPanelFrame) -> Void
        /// Stop the Chief's answer (Esc while it answers).
        public var stop: @MainActor () -> Void
        /// The eye: turn "sees your screen" off or on.
        public var toggleSeesScreen: @MainActor () -> Void = {}
        /// The panel came on screen (opened, or back after Home).
        public var opened: @MainActor () -> Void = {}

        /// - Parameters:
        ///   - toggleDock: Dock or Float.
        ///   - hide: Hide.
        ///   - moved: A drag or resize ended at this floating place.
        ///   - stop: Stop the Chief's answer; nothing by default.
        ///   - toggleSeesScreen: The eye's click; nothing by default.
        ///   - opened: The panel came on screen; nothing by default.
        public init(toggleDock: @escaping @MainActor () -> Void, hide: @escaping @MainActor () -> Void,
                    moved: @escaping @MainActor (ChiefPanelFrame) -> Void, stop: @escaping @MainActor () -> Void = {},
                    toggleSeesScreen: @escaping @MainActor () -> Void = {}, opened: @escaping @MainActor () -> Void = {}) {
            self.toggleDock = toggleDock
            self.hide = hide
            self.moved = moved
            self.stop = stop
            self.toggleSeesScreen = toggleSeesScreen
            self.opened = opened
        }
    }

    /// The bar's height (``ChiefPanelStyle/panel`` and docked).
    public static let barHeight: CGFloat = 30
    /// The grip strip's height (``ChiefPanelStyle/card`` and the collapsing styles grown).
    static let stripHeight: CGFloat = 18
    /// How far in from a floating panel's edge a press resizes it.
    static let resizeBand: CGFloat = 6
    /// The least a collapsing style grows to with the keys.
    static let grownSize = CGSize(width: 320, height: 360)

    /// The bar's buttons and the hand moves.
    public var actions: Actions
    /// Whether the held Chief is answering (``ChiefPanelContent``): Esc then stops it, as in Home, instead of hiding
    /// the panel.
    public var chiefIsAnswering: Bool { (chief as? any ChiefPanelContent)?.chiefIsAnswering == true }
    /// Floating (corners, shadow, drag, resize) or docked (square).
    public private(set) var floating = true
    /// How the floating panel looks; docked it always shows the bar.
    public var style: ChiefPanelStyle = .default {
        didSet { if style != oldValue { applyShape() } }
    }
    /// Where a press moves the panel (and, resting, a click opens it), in this view's coordinates (y down).
    public var gripRect: NSRect { bar.frame }
    /// Whether the Chief gets a look at the screen when the panel opens (the eye).
    public var seesScreen = true {
        didSet { if seesScreen != oldValue { applyEye() } }
    }
    /// Whether the panel's glass shows behind the chat.
    public var showsPanelGlass: Bool { !backdrop.isHidden }
    /// The glass plate under the message box (see-through styles), in this view's coordinates; nil without one.
    public var composerPlate: NSRect? { plate.isHidden ? nil : plate.frame }
    /// The glass plate behind the bar and the chat's header (see-through styles), in this view's coordinates; nil without one.
    public var headerPlate: NSRect? { header.isHidden ? nil : header.frame }
    /// The corner radius the panel draws now (0 docked).
    public var shapeCornerRadius: CGFloat { body.layer?.cornerRadius ?? 0 }
    /// The Chief view this panel shows now; nil while it is in Home's pane.
    public private(set) weak var chief: NSView?
    /// The panel's own window while it floats (``ChiefLauncherPanel``); nil keeps a floating panel in the window.
    public let launcher: ChiefLauncherPanel?

    private enum Chrome { case bar, strip, rest }
    private let backdrop = Glass.makeOverlayPanel(cornerRadius: Metrics.surfaceCornerRadius, interactive: true)
    private let bar = NSView()
    private let title: NSTextField
    private let dockButton = NSButton()
    private let hideButton = NSButton()
    private let eyeButton = NSButton()
    /// The see-through styles' veil under the message box, so what is typed stays readable over any workspace.
    private let plate = NSView()
    /// The see-through styles' veil behind the bar and the chat's header (its name and picture): only there, so the
    /// header reads over busy text while the bubbles below still show the workspace. Its bottom fades out.
    ///
    /// A veil, not glass: glass here samples nothing under it (the terminal draws in its own layer), so a glass plate
    /// drew nothing in the captures and the terminal's text ran straight through the Chief's name.
    private let header = NSView()
    private let gripMark = NSImageView()
    private let chiefMark = NSImageView()
    private let body = NSView()
    /// The floating place (or the docked rect), in the superview (y up): a collapsing style's whole chat.
    private var expanded = NSRect.zero
    /// A click on the resting shape grows it until the keys leave.
    private var holdsOpen = false
    private var press: (start: NSPoint, frame: NSRect, expanded: NSRect, edges: Set<NSRectEdge>, moved: Bool)?
    private var styleTask: Task<Void, Never>?
    private var sourced: Look?

    /// - Parameters:
    ///   - title: The bar's name of the Chief.
    ///   - launcher: The window the panel floats in, over every app; nil floats it inside the window.
    ///   - actions: The bar's buttons and the hand moves.
    public init(title: String, launcher: ChiefLauncherPanel? = nil, actions: Actions) {
        self.title = NSTextField(labelWithString: title)
        self.launcher = launcher
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
        for (button, id) in [(dockButton, "window.chiefPanel.dock"), (hideButton, "window.chiefPanel.hide"), (eyeButton, "window.chiefPanel.seesScreen")] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.setAccessibilityIdentifier(id)
            button.target = self
        }
        dockButton.action = #selector(toggleDockPressed)
        hideButton.action = #selector(hidePressed)
        eyeButton.action = #selector(eyePressed)
        applyEye()
        let hide = String(localized: "layout.chiefPanel.hide", defaultValue: "Hide the Chief", bundle: .module)
        hideButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: hide)
        hideButton.themedToolTip = hide
        let grip = String(localized: "layout.chiefPanel.grip", defaultValue: "Move the Chief", bundle: .module)
        gripMark.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: grip)
        gripMark.contentTintColor = .tertiaryLabelColor
        gripMark.frameCenterRotation = 90
        bar.themedToolTip = grip
        chiefMark.image = NSImage(systemSymbolName: "bubble.left.fill",
                                  accessibilityDescription: String(localized: "layout.chiefPanel.open", defaultValue: "Open the Chief", bundle: .module))
        chiefMark.contentTintColor = .controlAccentColor
        chiefMark.symbolConfiguration = .init(scale: .large)
        for view in [self.title, eyeButton, dockButton, hideButton, gripMark, chiefMark] { bar.addSubview(view) }
        body.wantsLayer = true
        for veil in [plate, header] {
            veil.wantsLayer = true
            veil.isHidden = true
        }
        plate.layer?.mask = CAGradientLayer()
        header.layer?.mask = CAGradientLayer()
        addSubview(backdrop)
        addSubview(plate)
        addSubview(header)
        addSubview(body)
        addSubview(bar)
        setFloating(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public var isFlipped: Bool { true }
    override public var mouseDownCanMoveWindow: Bool { false }
    /// The grip and the rim (the presses ``hitTest(_:)`` keeps for the panel) move or resize it on the first click,
    /// as a title bar does, even while another window holds the keys: without it that click only made the window key.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { floating }

    /// A press in the window's top row on a floating panel moves the panel, never the window; on a docked panel's
    /// bar it moves the window, as any titlebar background does.
    public func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress {
        !floating && bar.frame.contains(convert(windowPoint, from: nil)) && press == nil ? .movesWindow : .staysPut
    }

    /// Follows the settings live: the style from `source` and the eye from `seesScreen`, their values now, then each
    /// change.
    public func follow(_ source: @escaping @MainActor @Sendable () -> ChiefPanelStyle,
                       seesScreen: @escaping @MainActor @Sendable () -> Bool = { true }) {
        styleTask?.cancel()
        let (first, later) = ObservationStream.current { Look(style: source(), seesScreen: seesScreen()) }
        apply(first)
        styleTask = Task { [weak self] in
            for await next in later {
                guard let self else { return }
                if next != self.sourced { self.apply(next) }
            }
        }
    }

    /// What the settings say: kept, so a direct change of ``style`` stands until the settings change.
    private struct Look: Equatable, Sendable { var style: ChiefPanelStyle; var seesScreen: Bool }

    private func apply(_ look: Look) {
        sourced = look
        style = look.style
        seesScreen = look.seesScreen
    }

    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview != nil { actions.opened() }
    }

    /// Puts the panel on screen for the window whose content is `host`.
    public func mount(in host: NSView) {
        if superview !== host { host.addSubview(self) }
    }

    /// Takes the panel off screen.
    public func unmount() {
        removeFromSuperview()
    }

    /// Whether the panel shows for the window whose content is `host`.
    public func isShown(in host: NSView) -> Bool { superview === host }

    /// Floating or docked: the corners, the shadow and the Dock/Float button follow.
    public func setFloating(_ floating: Bool) {
        self.floating = floating
        applyDockedWorkspaceChrome(floating: floating)
        layer?.masksToBounds = false
        let label = floating ? String(localized: "layout.chiefPanel.dock", defaultValue: "Dock the Chief to the Side", bundle: .module)
            : String(localized: "layout.chiefPanel.float", defaultValue: "Float the Chief", bundle: .module)
        dockButton.image = NSImage(systemSymbolName: floating ? "sidebar.left" : "macwindow.on.rectangle", accessibilityDescription: label)
        dockButton.themedToolTip = label
        applyShape()
    }

    /// Takes `view` (the Chief's) into the panel, out of wherever it was; nothing when it is here already.
    public func hold(_ view: NSView) {
        guard view.superview !== body else { return }
        chief = view
        view.removeFromSuperview()
        view.autoresizingMask = []
        body.addSubview(view)
        applyShape()
    }

    /// Lets the held view go, for Home's pane to take back; the view it held, nil when none.
    @discardableResult
    public func release() -> NSView? {
        guard let view = chief else { return nil }
        chief = nil
        if view.superview === body { view.removeFromSuperview() }
        view.autoresizingMask = [.width, .height]
        view.shadow = nil
        (view as? any ChiefPanelContent)?.chiefShowsThrough = false
        return view
    }

    /// The keyboard is in the held Chief.
    public var hasKeys: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    /// The held Chief's message box (`target`, else the first view in it that takes the keys) takes the keys; a
    /// resting style grows into the chat first.
    public func focusChief(_ target: NSView? = nil) {
        guard let chief, let window else { return }
        holdsOpen = true
        applyShape()
        layoutSubtreeIfNeeded()
        if !window.makeFirstResponder(target ?? firstKeyView(in: chief) ?? chief), !hasKeys {
            holdsOpen = false
            applyShape()
        }
    }

    /// Places the panel for `panel` in its superview's `bounds` (y up) and returns the stage's area (y down): all
    /// of it under a floating panel, the rest beside a docked one, `gap` apart. A press in progress keeps the
    /// panel where the hand has it.
    public func place(_ panel: ChiefPanel, in bounds: CGRect, gap: CGFloat) -> CGRect {
        let size = bounds.size
        var (rect, stage) = panel.split(CGRect(origin: .zero, size: size))
        switch panel.dockedEdge {
        case .left?: stage = CGRect(x: stage.minX + gap, y: stage.minY, width: max(0, stage.width - gap), height: stage.height)
        case .right?: stage.size.width = max(0, stage.width - gap)
        case .top?: stage = CGRect(x: stage.minX, y: stage.minY + gap, width: stage.width, height: max(0, stage.height - gap))
        case .bottom?: stage.size.height = max(0, stage.height - gap)
        case nil: rect = panel.floatingFrame.rect(in: size, minimum: leastFloating)
        }
        guard press == nil else { return stage }
        expanded = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height).integral
        applyShape()
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

    /// The window's first responder moved (the window tells its panel): a collapsing style grows with the keys and
    /// rests without them.
    public func firstResponderDidChange() {
        guard press == nil else { return }
        if !hasKeys { holdsOpen = false }
        if floating && style.collapses { applyShape() }
    }

    // MARK: Shapes

    private var chrome: Chrome {
        guard floating else { return .bar }
        switch style {
        case .panel: return .bar
        case .card, .seeThrough: return .strip
        case .composeBar, .pill, .bubble, .seeThroughBar: return holdsOpen || hasKeys ? .strip : .rest
        }
    }

    /// The resting shape's size for the style.
    private var restSize: CGSize {
        switch style {
        case .composeBar, .seeThroughBar: CGSize(width: 240, height: 52)
        case .pill: CGSize(width: 200, height: 40)
        default: CGSize(width: 44, height: 44)
        }
    }

    /// Whether the style rests as a message bar along its place's bottom (the compose bar, glass or see-through).
    private var restsAsBar: Bool { style == .composeBar || style == .seeThroughBar }

    /// The smallest floating place the style keeps: a collapsing style's place may be as small as its resting shape.
    private var leastFloating: CGSize { style.collapses ? restSize : ChiefPanelFrame.minimumSize }

    /// The resting shape in `place` (y up): along its bottom, the compose bars full width, the pill and the bubble
    /// at its right.
    private func rest(in place: NSRect) -> NSRect {
        switch style {
        case .composeBar, .seeThroughBar: return NSRect(x: place.minX, y: place.minY, width: place.width, height: restSize.height)
        case .pill:
            let w = min(place.width, 320)
            return NSRect(x: place.maxX - w, y: place.minY, width: w, height: restSize.height)
        default: return NSRect(x: place.maxX - restSize.width, y: place.minY, width: restSize.width, height: restSize.height)
        }
    }

    /// A collapsing style's chat grown from `place`: at least ``grownSize``, from the same bottom corner, inside the
    /// window.
    private func grown(from place: NSRect) -> NSRect {
        let w = max(place.width, Self.grownSize.width), h = max(place.height, Self.grownSize.height)
        let x = restsAsBar ? place.minX : place.maxX - w
        return inside(NSRect(x: x, y: place.minY, width: w, height: h))
    }

    /// `rect` moved (and, past the window's size, shrunk) to lie inside the superview.
    private func inside(_ rect: NSRect) -> NSRect {
        guard let host = superview?.bounds, host.width > 0, host.height > 0 else { return rect }
        let w = min(rect.width, host.width), h = min(rect.height, host.height)
        return NSRect(x: min(max(host.minX, rect.minX), host.maxX - w), y: min(max(host.minY, rect.minY), host.maxY - h), width: w, height: h)
    }

    /// The floating place that keeps the resting shape at `shape` (y up), from the place `before` a drag.
    private func place(resting shape: NSRect, before: NSRect) -> NSRect {
        let top = superview?.bounds.maxY ?? shape.maxY
        let h = max(shape.height, min(before.height, top - shape.minY))
        switch style {
        case .composeBar, .seeThroughBar: return NSRect(x: shape.minX, y: shape.minY, width: shape.width, height: h)
        default:
            let w = max(shape.width, min(before.width, shape.maxX - (superview?.bounds.minX ?? 0)))
            return NSRect(x: shape.maxX - w, y: shape.minY, width: w, height: h)
        }
    }

    /// A floating panel's corner radius: a card inside the window, concentric with the window's corners across the
    /// gutter like the main pane (10 pt in a 16 pt window), or the radius `layout.paneCornerRadius` sets.
    private static var cardCornerRadius: CGFloat {
        Metrics.windowConcentricCornerRadius(windowCornerRadius: Metrics.standardWindowCornerRadius,
                                             edgeInset: max(Metrics.mainPaneGutter, PaneTabRowRim.height),
                                             setting: DesignSettings.shared.paneChrome.cornerRadius.map(Metrics.scale))
    }

    private func applyShape() {
        guard superview != nil, expanded.width > 0 else { needsLayout = true; return }
        let chrome = chrome
        let shown = !floating ? expanded : chrome == .rest ? rest(in: expanded) : style.collapses ? grown(from: expanded) : expanded
        if frame != shown { frame = shown }
        let card = Self.cardCornerRadius
        let radius: CGFloat = !floating ? 0 : chrome == .rest ? min(shown.height / 2, restsAsBar ? card : shown.height / 2) : card
        backdrop.cornerRadius = radius
        header.layer?.cornerRadius = card
        plate.layer?.cornerRadius = chrome == .rest ? radius : card
        body.layer?.cornerRadius = radius
        body.layer?.masksToBounds = floating
        let clear = floating && style.isSeeThrough
        backdrop.isHidden = clear
        plate.isHidden = !clear
        header.isHidden = !clear || chrome == .rest
        chief?.shadow = nil  // no halo over the whole chat (it blurred every bubble); the header has its plate
        if let content = chief as? any ChiefPanelContent, content.chiefShowsThrough != clear { content.chiefShowsThrough = clear }
        body.isHidden = chrome == .rest && style == .bubble
        title.isHidden = chrome != .bar
        dockButton.isHidden = chrome == .rest
        eyeButton.isHidden = chrome == .rest
        hideButton.isHidden = chrome == .rest
        gripMark.isHidden = chrome != .rest || style == .bubble
        chiefMark.isHidden = !(chrome == .rest && style == .bubble)
        window?.invalidateCursorRects(for: self)
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        backdrop.frame = bounds
        let w = bounds.width, h = bounds.height
        switch chrome {
        case .bar, .strip:
            let strip = chrome == .bar ? Self.barHeight : Self.stripHeight
            let button: CGFloat = chrome == .bar ? 24 : 16
            bar.frame = NSRect(x: 0, y: 0, width: w, height: strip)
            hideButton.frame = NSRect(x: w - button - (chrome == .bar ? 6 : 4), y: (strip - button) / 2, width: button, height: button)
            dockButton.frame = hideButton.frame.offsetBy(dx: -button - 2, dy: 0)
            eyeButton.frame = dockButton.frame.offsetBy(dx: -button - 2, dy: 0)
            title.sizeToFit()
            title.frame.origin = NSPoint(x: 12, y: (strip - title.frame.height) / 2)
            body.frame = NSRect(x: 0, y: strip, width: w, height: max(0, h - strip))
            chief?.frame = body.bounds
            plate.frame = NSRect(x: 0, y: max(strip, h - Self.plateHeight), width: w, height: min(Self.plateHeight, h - strip))
            let headerHeight = (chief as? any ChiefPanelContent)?.chiefHeaderHeight ?? 0
            header.frame = NSRect(x: 0, y: 0, width: w, height: min(h, strip + headerHeight + Self.headerPlateFade))
            Self.fade(header, atBottom: true)
            Self.fade(plate, atBottom: false)
        case .rest:
            let grip: CGFloat = style == .bubble ? w : style == .pill ? 16 : 20
            bar.frame = NSRect(x: 0, y: 0, width: grip, height: h)
            gripMark.frame = NSRect(x: (grip - 14) / 2 + 2, y: (h - 14) / 2, width: 14, height: 14)
            chiefMark.frame = bar.bounds
            body.frame = NSRect(x: grip, y: 0, width: max(0, w - grip), height: h)
            // The chat keeps its grown height, its bottom (the message box) showing through the shape.
            chief?.frame = NSRect(x: 0, y: 0, width: body.bounds.width, height: max(h, grown(from: expanded).height - Self.stripHeight))
            plate.frame = bounds
            Self.fade(plate, atBottom: nil)
        }
        applyVeils()
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVeils()
    }

    /// The veils' color: the dialogs' glass veil (``FloatingGlassStyle/dialog``), at ``veilAlpha`` so text reads over
    /// any workspace in light and dark.
    private func applyVeils() {
        let color = performWithTheme { Palette.veil(of: .dialog).withAlphaComponent(Self.veilAlpha) }.cgColor
        for veil in [plate, header] where veil.layer?.backgroundColor != color { veil.layer?.backgroundColor = color }
    }

    /// Lays `veil`'s mask: solid, fading to clear over ``headerPlateFade`` at its bottom (`atBottom`) or top, the
    /// edge toward the chat; solid all over when nil.
    private static func fade(_ veil: NSView, atBottom: Bool?) {
        guard let mask = veil.layer?.mask as? CAGradientLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = veil.bounds
        mask.colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: atBottom == nil ? 1 : 0)]
        let fade = Double(min(1, headerPlateFade / max(veil.bounds.height, 1)))
        mask.locations = [0, NSNumber(value: 1 - fade), 1]
        // From the solid edge to the fading one; the unit square's y = 0 is at the top only on flipped contents.
        let top: CGFloat = veil.layer?.contentsAreFlipped() == true ? 0 : 1
        mask.startPoint = CGPoint(x: 0.5, y: atBottom == true ? top : 1 - top)
        mask.endPoint = CGPoint(x: 0.5, y: atBottom == true ? 1 - top : top)
        CATransaction.commit()
    }

    @objc private func toggleDockPressed() { actions.toggleDock() }
    @objc private func hidePressed() { actions.hide() }
    @objc private func eyePressed() { actions.toggleSeesScreen() }

    /// The eye's look: open while the Chief gets a look at the screen when the panel opens, crossed out when not.
    private func applyEye() {
        let label = seesScreen
            ? String(localized: "layout.chiefPanel.seesScreen.on", defaultValue: "Chief Sees Your Screen When It Opens", bundle: .module)
            : String(localized: "layout.chiefPanel.seesScreen.off", defaultValue: "Chief Does Not See Your Screen", bundle: .module)
        eyeButton.image = NSImage(systemSymbolName: seesScreen ? "eye" : "eye.slash", accessibilityDescription: label)
        eyeButton.contentTintColor = seesScreen ? .controlAccentColor : .secondaryLabelColor
        eyeButton.themedToolTip = label
    }

    /// The see-through plate's height: the message box and its margin.
    static let plateHeight: CGFloat = 64
    /// How far a veil fades out at its edge toward the chat, below the header (or above the message box).
    public static let headerPlateFade: CGFloat = 14
    /// The veils' opacity: dense enough that busy text behind reads as texture, still translucent.
    private static let veilAlpha: CGFloat = 0.82

    // MARK: Moving and resizing (floating only)

    /// The edges a press at `point` (this view's coordinates, y down) resizes, as the superview names them (y up);
    /// none while the panel rests.
    private func resizeEdges(at point: NSPoint) -> Set<NSRectEdge> {
        guard chrome != .rest else { return [] }
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
        // The rim's resize band and the grip's empty space are the panel's own: they move or resize it.
        if !resizeEdges(at: local).isEmpty { return self }
        let hit = super.hitTest(point)
        if bar.frame.contains(local), let hit, hit === bar || !(hit is NSButton) && hit.isDescendant(of: bar) { return self }
        return hit
    }

    override public func mouseDown(with event: NSEvent) {
        guard floating, let superview else { return super.mouseDown(with: event) }
        press = (superview.convert(event.locationInWindow, from: nil), frame, expanded, resizeEdges(at: convert(event.locationInWindow, from: nil)), false)
    }

    override public func mouseDragged(with event: NSEvent) {
        guard var press, let superview else { return super.mouseDragged(with: event) }
        let point = superview.convert(event.locationInWindow, from: nil)
        let dx = point.x - press.start.x, dy = point.y - press.start.y
        if !press.moved, hypot(dx, dy) < 3 { return }
        press.moved = true
        self.press = press
        let start = press.frame, least = leastFloating
        var next = start
        if press.edges.isEmpty { next.origin = NSPoint(x: start.minX + dx, y: start.minY + dy) }
        if press.edges.contains(.minX) { next.origin.x = min(start.maxX - least.width, start.minX + dx); next.size.width = start.maxX - next.minX }
        if press.edges.contains(.maxX) { next.size.width = max(least.width, start.width + dx) }
        if press.edges.contains(.minY) { next.origin.y = min(start.maxY - least.height, start.minY + dy); next.size.height = start.maxY - next.minY }
        if press.edges.contains(.maxY) { next.size.height = max(least.height, start.height + dy) }
        next = press.edges.isEmpty ? inside(next).integral : next.intersection(superview.bounds).integral
        frame = next
        expanded = chrome == .rest ? place(resting: next, before: press.expanded).integral : next
    }

    override public func mouseUp(with event: NSEvent) {
        guard let press, let superview else { return super.mouseUp(with: event) }
        self.press = nil
        guard press.moved else {
            if chrome == .rest { focusChief() }
            return
        }
        let size = superview.bounds.size
        actions.moved(ChiefPanelFrame.fitting(CGRect(x: expanded.minX, y: size.height - expanded.maxY, width: expanded.width, height: expanded.height),
                                              in: size, minimum: leastFloating))
    }

    override public func resetCursorRects() {
        guard floating else { return }
        addCursorRect(bar.frame, cursor: .openHand)
        guard chrome != .rest else { return }
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
