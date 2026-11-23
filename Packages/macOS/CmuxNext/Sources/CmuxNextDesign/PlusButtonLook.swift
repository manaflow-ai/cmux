public import AppKit
import CmuxNextDesignTokens
public import QuartzCore

/// The window's one + button: the tab bar's New Tab + is the standard every add control draws (Lawrence 2026-11-15:
/// "we should make the new tab plus button the standard for all plus buttons (abstract it into a component). and
/// then we need to use the same plus button in the sidebar plus button").
///
/// It draws a hover fill and the + (``CGPath/addGlyph(center:scale:)``, ``Metrics/addGlyphExtent`` at
/// ``Metrics/addGlyphLineWidth``) into its host view's layer; the host keeps its own events, accessibility and
/// menus. The + is the same size, weight and ink in every host and every state: secondary at rest, primary on hover,
/// the lit ink while its menu is open (a held + keeps its hover ink). A fill shows only on hover and press, in the shared
/// ``hoverStyle``. Hosts: the tab bar's New Tab + (`NewTabButtonView`) and the sidebar's + buttons
/// (`SidebarIconButton.plus`: New Workspace, a group's, a machine's and an empty group's). The Spaces strip, which
/// draws its marks in one `draw(_:)`, strokes the same + through ``drawGlyph(in:center:ink:)``.
/// The `plus-button` guardrail (scripts/cmux-next/guardrails.py) refuses a + drawn any other way.
@MainActor
public final class PlusButtonLook {
    /// What the pointer and the host's menu are doing to the +.
    public nonisolated struct State: Equatable, Sendable {
        /// The pointer is over the +.
        public var hovering: Bool
        /// The + is held down.
        public var pressed: Bool
        /// A menu the + opened is open: it stays lit, as while pressed.
        public var menuOpen: Bool
        /// The other segment of a split `+ ⌄` is hovered (``Segment/leading``): the + takes half the hover fill.
        public var siblingHovered: Bool

        public init(hovering: Bool = false, pressed: Bool = false, menuOpen: Bool = false, siblingHovered: Bool = false) {
            self.hovering = hovering
            self.pressed = pressed
            self.menuOpen = menuOpen
            self.siblingHovered = siblingHovered
        }

        /// Hovered, or held by its menu.
        public var lit: Bool { hovering || menuOpen }
        /// Pressed, or held by its menu.
        public var down: Bool { pressed || menuOpen }
    }

    /// Where the + sits in its control.
    public nonisolated enum Segment: Sendable, Equatable {
        /// A + of its own: its fill rounds every corner.
        case alone
        /// The leading half of a split `+ ⌄` (the tab bar's `TabTrailingButtons.split`): its fill spans its frame and
        /// rounds only the leading corners; the ⌄ beside it rounds the trailing ones.
        case leading
    }

    /// Every + button's hover style: a plate (the tab bar's default split look's +). A host may change it for a
    /// look that applies to its own row of controls (the tab bar's Debug `tabs.trailingButtons`).
    public static let defaultHoverStyle: ChromeHoverStyle = .plate

    public let fillLayer = CALayer()
    public let glyphLayer = CAShapeLayer()
    private weak var host: NSView?

    /// The hover look: ``defaultHoverStyle`` unless the host's row sets its own.
    public var hoverStyle: ChromeHoverStyle = PlusButtonLook.defaultHoverStyle {
        didSet { if oldValue != hoverStyle { host?.needsLayout = true; refresh(animated: false) } }
    }
    public var segment: Segment = .alone {
        didSet { if oldValue != segment { host?.needsLayout = true; refresh(animated: false) } }
    }
    /// A ⌄ after the + in the same control (the tab bar's + when a press opens its menu).
    /// A + in a tab bar (the New Tab +, beside the tabs and the pane's ⋮): its fill rounds as a tab pill
    /// (``Metrics/tabBarControlCornerRadius(fitting:)``, Lawrence 2026-11-20). Off (the sidebar's and Home's +), it
    /// keeps the proportional corner on its own side, so a small + never rounds into a circle at a large density.
    public var roundsAsTabBarControl = false {
        didSet { if oldValue != roundsAsTabBarControl { host?.needsLayout = true } }
    }
    public var showsChevron = false {
        didSet { if oldValue != showsChevron { host?.needsLayout = true } }
    }
    /// A fixed ink for a + on a colored surface (a group header's bar draws every control in the group's ink); nil
    /// takes ``glyphInk(hovering:pressed:)``. The fill still shows hover and press.
    public var inkOverride: NSColor? {
        didSet { if oldValue != inkOverride { refresh(animated: false) } }
    }
    public private(set) var state = State()
    /// The motion gate the hover fill fades through: the tab bar's (`Motion.tabs`) by default; a sidebar + takes the
    /// sidebar buttons' feedback gate, so it fades as its neighbours do.
    public var motion: MotionGate = Motion.tabs

    /// Adds the fill and the glyph to `host`'s layer (the host must be layer-backed), under its other sublayers.
    public init(host: NSView) {
        self.host = host
        host.wantsLayer = true
        fillLayer.cornerRadius = Metrics.tabCornerRadius
        fillLayer.cornerCurve = Metrics.tabCornerCurve
        fillLayer.actions = ["bounds": NSNull(), "position": NSNull()]
        glyphLayer.fillColor = nil
        glyphLayer.lineWidth = Metrics.addGlyphLineWidth
        glyphLayer.lineCap = .round
        glyphLayer.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull()]
        host.layer?.insertSublayer(fillLayer, at: 0)
        host.layer?.insertSublayer(glyphLayer, above: fillLayer)
    }

    /// Lays the fill and the glyph out in `bounds` (the host's), on the device pixels of `scale`. Call from the
    /// host's `layout()`.
    public func layout(in bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let geometry = Self.geometry(in: bounds, segment: segment, hoverStyle: hoverStyle, showsChevron: showsChevron,
                                     roundsAsTabBarControl: roundsAsTabBarControl, scale: scale)
        fillLayer.frame = geometry.fill
        fillLayer.cornerRadius = geometry.cornerRadius
        fillLayer.cornerCurve = Metrics.tabCornerCurve
        fillLayer.maskedCorners = geometry.corners
        glyphLayer.frame = bounds
        glyphLayer.contentsScale = scale
        let path = CGMutablePath()
        path.addPath(CGPath.addGlyph(center: geometry.glyphCenter, scale: scale)) // plus-button-allow: the look itself
        if showsChevron {
            let x = geometry.glyphCenter.x + Metrics.addGlyphExtent / 2 + Metrics.space3
            let half = Self.chevronHalfWidth, rise = Self.chevronRise
            path.move(to: CGPoint(x: x - half, y: geometry.glyphCenter.y - rise / 2))
            path.addLine(to: CGPoint(x: x, y: geometry.glyphCenter.y + rise / 2))
            path.addLine(to: CGPoint(x: x + half, y: geometry.glyphCenter.y - rise / 2))
        }
        glyphLayer.path = path
        CATransaction.commit()
    }

    /// Shows `state`: fades the fill in or out (`animated`, through the tabs' motion gate) and sets the ink.
    public func apply(_ state: State, animated: Bool) {
        let changed = state != self.state
        self.state = state
        refresh(animated: animated && changed)
    }

    /// Repaints the current state in the host's theme (an appearance change, a token change).
    public func refresh(animated: Bool = false) {
        let token = animated ? ChromeHover.fade(showing: state.lit || state.down, pressed: state.down) : nil
        // An instant change also ends a fill still easing in.
        if (token.map(motion.duration) ?? 0) == 0 { fillLayer.removeAnimation(forKey: "backgroundColor") }
        let paint = { [self] in
            fillLayer.backgroundColor = Self.fill(state, hoverStyle: hoverStyle, segment: segment)?.cgColor
            // A held + keeps its hover ink; only the fill changes (design/pressed-state.md, Lawrence 2026-11-15). An open
            // menu is an "on" state and lights the ink.
            // On a popover's glass the secondary and primary inks are fit to the glass over any page.
            let onGlass = state.menuOpen ? nil
                : host?.glassInk(state.hovering || state.pressed ? \.textPrimary : \.textSecondary,
                                 minimum: CmuxDialogButtonLook.minimumContrast)
            glyphLayer.strokeColor = (inkOverride ?? onGlass ?? Self.ink(state)).cgColor
            glyphLayer.lineWidth = Metrics.addGlyphLineWidth
        }
        motion.transaction(token) {
            if let host { host.performWithTheme(paint) } else { paint() }
        }
    }

    // MARK: The look, as values (tests and the Spaces strip read these)

    /// Where the fill and the glyph go in a host's `bounds`.
    public nonisolated struct Geometry: Equatable, Sendable {
        public var fill: CGRect
        public var cornerRadius: CGFloat
        public var corners: CACornerMask
        public var glyphCenter: CGPoint
    }

    /// The fill's frame, its corner and the glyph's center for a host of `bounds`. A lone + fills a square centered
    /// in its frame (a circle in the circle look); the split's leading segment fills its whole frame (the pane ⋮'s
    /// square, ``Metrics/tabBarControlSide``); a + with its own ⌄ fills its frame less a `space1` margin each side.
    /// With `roundsAsTabBarControl` (a tab bar's +) every fill rounds as a tab pill; else by the tabs' ratio on its side.
    public static func geometry(in bounds: CGRect, segment: Segment, hoverStyle: ChromeHoverStyle,
                                showsChevron: Bool, roundsAsTabBarControl: Bool = false, scale: CGFloat) -> Geometry {
        let side = min(bounds.width, bounds.height)
        let square = CGRect(x: bounds.minX + (bounds.width - side) / 2, y: bounds.minY + (bounds.height - side) / 2, width: side, height: side)
        let split = segment == .leading && !showsChevron
        let fill = split ? bounds : showsChevron ? bounds.insetBy(dx: Metrics.space1, dy: (bounds.height - side) / 2) : square
        // A tab bar's + rounds as a tab pill, at most half its short side (Lawrence 2026-11-20: "roundness of this
        // button needs to always be same as roundness of tabs"), its ⌄ too (`splitCornerRadius`). Any other + rounds
        // by its own short side at the tabs' ratio (Lucas 2026-11-15: one shape at every density).
        let corner = hoverStyle == .circle && !showsChevron && !split ? side / 2 // radius-allow: the opt-in circle hover look
            : roundsAsTabBarControl ? Metrics.tabBarControlCornerRadius(fitting: fill.size)
            : split ? Metrics.buttonCornerRadius(proportionalTo: min(TitlebarBandButton.side, Metrics.tabHeight))
            : Metrics.buttonCornerRadius(proportionalTo: min(fill.width, fill.height))
        let corners: CACornerMask = split ? [.layerMinXMinYCorner, .layerMinXMaxYCorner] : allCorners
        // In the split look the + leans half a step toward its ⌄, which leans back, so the pair reads as one control.
        let lean = split ? Metrics.space1 / 2 : 0
        let scale = max(scale, 1)
        let center = CGPoint(x: ((square.midX - (showsChevron ? Metrics.space2 : 0) + lean) * scale).rounded() / scale,
                             y: (square.midY * scale).rounded() / scale)
        return Geometry(fill: fill, cornerRadius: corner, corners: corners, glyphCenter: center)
    }

    /// A tab bar's split control's corner, on the + and on its ⌄ alike: a tab pill's, on the control's square
    /// (``Metrics/tabBarControlCornerRadius(fitting:)``), so the `+ ⌄` rounds as the tabs and the ⋮ beside it.
    public static var splitCornerRadius: CGFloat { Metrics.tabBarControlCornerRadius() }

    /// The fill for `state`: the hover fill under the pointer, the pressed fill while held, half the hover fill on a
    /// split segment while its sibling is hovered, else none. The glyph look never fills. Call inside a theme scope.
    public static func fill(_ state: State, hoverStyle: ChromeHoverStyle, segment: Segment) -> NSColor? {
        guard hoverStyle.paintsFill else { return nil }
        if state.lit || state.down { return ChromeHover.fillColor(.init(hovering: state.lit, pressed: state.down)) }
        guard segment == .leading, state.siblingHovered else { return nil }
        return ChromeHover.fillColor(.init(hovering: true)).map { $0.withAlphaComponent($0.alphaComponent / 2) }
    }

    /// The + buttons' ink (and the ⌄ beside one): secondary at rest, primary on hover, the lit ink while pressed or
    /// while its menu is open. Call inside a theme scope.
    public static func glyphInk(hovering: Bool, pressed: Bool) -> NSColor {
        pressed ? Palette.litGlyph : (hovering ? Palette.textPrimary : Palette.textSecondary)
    }

    /// The ink for `state`: secondary at rest, primary while hovered or held, the lit ink while its menu is open.
    public static func ink(_ state: State) -> NSColor {
        glyphInk(hovering: state.hovering || state.pressed, pressed: state.menuOpen)
    }

    /// Strokes the + centered on `center` in the current graphics context, in `ink`: the Spaces strip's +, which
    /// draws its marks in one `draw(_:)`.
    public static func drawGlyph(in context: CGContext, center: CGPoint, ink: NSColor) {
        let scale = context.userSpaceToDeviceSpaceTransform.a
        context.saveGState()
        context.addPath(CGPath.addGlyph(center: center, scale: abs(scale) > 0 ? abs(scale) : 2)) // plus-button-allow: the look itself
        context.setLineWidth(Metrics.addGlyphLineWidth)
        context.setLineCap(.round)
        context.setStrokeColor(ink.cgColor)
        context.strokePath()
        context.restoreGState()
    }

    public nonisolated static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner,
                                                             .layerMaxXMinYCorner, .layerMaxXMaxYCorner]

    /// Half the ⌄'s width: three quarters of the +'s arm (``Metrics/addGlyphExtent``), so it reads as the +'s
    /// companion, not its peer. The ⌄ is half as tall as it is wide (``chevronRise``), the SF Symbol chevron's
    /// proportion.
    public static var chevronHalfWidth: CGFloat { Metrics.addGlyphExtent / 2 * 0.75 }

    /// The ⌄'s height: its half width, so it is twice as wide as it is tall.
    public static var chevronRise: CGFloat { chevronHalfWidth }
}
