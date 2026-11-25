public import CmuxNextDesignTokens

/// The colors one dialog button draws in one theme (``CmuxDialogButtonView``), every ink at least
/// WCAG AA (4.5:1) on what is under it:
/// - default (Return): the theme's solid accent fill (the primary text color unless
///   `appearance.accent` names a hue) with its on-accent ink, as the web pages' primary button
///   draws, so the button Return presses reads first at a glance. It was a gray 3 to 4% denser
///   than Cancel's.
/// - destructive: white on a solid danger fill, deepened until white reads at 4.5:1, as macOS draws a
///   destructive button. `filledDestructive: false` gives the tinted alternative (the danger ink on a faint danger
///   wash, lifted to 4.5:1 over the card), kept for the design call (manaflow-ai/cmux#13742). The theme's `danger` is fit only to
///   3:1 (a mark's floor): over the glass it measured 2.1:1 (debug.dialog_strip, 2026-10-28).
/// - cancel and normal: the selection fill (gray, or the accent's tint in an accent theme), a step
///   above the hover fill they had, so each reads as a button on the glass.
///
/// A solid fill carries its own contrast whatever shows through the glass; a translucent one is
/// fit over ``cardSurfaces(_:)``.
///
/// A disabled button (`isEnabled: false`) is dimmed in its colors, not by fading the whole view: its
/// fill goes halfway to the card (a translucent one to half its alpha) and its title halfway to the
/// fill, then back toward its pole until it reads at ``disabledMinimumContrast``. A view faded to 45%
/// read its title at 1.1:1 on a light theme's Sign In button (NativeControlContrastAuditTests).
public nonisolated struct CmuxDialogButtonLook: Equatable, Sendable {
    public enum State: Sendable, CaseIterable { case rest, hover, pressed }

    /// The button's fill (translucent for cancel, normal and a tinted destructive button).
    public var fill: ThemeRGB
    /// The title's ink.
    public var title: ThemeRGB
    /// The key hint's ink, quieter than the title and still 4.5:1.
    public var keyHint: ThemeRGB
    /// The opaque colors the inks are read on: the fill over each card surface.
    public var surfaces: [ThemeRGB]
    /// The card the button sits on, as glass (it shows as the scrimmed window): the focus ring's gap.
    public var card: ThemeRGB
    /// The card under Reduce Transparency (the opaque popup surface): the gap on that card.
    public var opaqueCard: ThemeRGB
    /// The keyboard focus ring: the theme's focus ring, moved toward its pole until it reads at
    /// ``focusMinimumContrast`` on both card surfaces (on a gray Cancel it is the only sign of focus).
    public var focusRing: ThemeRGB

    /// WCAG's least contrast for a focus indicator against what is next to it.
    public static let focusMinimumContrast = 3.0

    /// The least contrast of every ink on every surface under it.
    public static let minimumContrast = 4.5

    /// What a cancel or normal title asks above ``minimumContrast`` where some ink can give it: its translucent fill
    /// sits on several grounds at once, and a title fit to exactly 4.5:1 on a popover's glass over a black page read
    /// 4.31:1 in the capture (Rose Pine Dawn's Cancel, Grass's 4.39:1, NativeControlContrastAuditTests).
    static let translucentTitleHeadroom = 0.35

    /// The least contrast of a disabled button's inks: dimmer than an enabled title, still legible
    /// (WCAG exempts disabled controls; cmux holds them above its 2.5:1 legible floor).
    public static let disabledMinimumContrast = 3.0

    /// `quiet` draws a destructive button as red text with no fill at rest, a faint danger wash under the
    /// pointer (``CmuxDialogSpec/Layout/safeDefault``: the choices a person should not reach for first).
    /// `isEnabled: false` gives the disabled look (see the type's discussion).
    public init(role: CmuxDialogButton.Role, tokens: ThemeTokens, state: State = .rest, filledDestructive: Bool = true,
                quiet: Bool = false, isEnabled: Bool = true, card: [ThemeRGB]? = nil) {
        let card = card ?? Self.cardSurfaces(tokens)
        // Hover and pressed move a solid fill toward the card a little, a translucent one up a step.
        let step = switch state { case .rest: 0.0; case .hover: 0.1; case .pressed: 0.2 }
        var fill: ThemeRGB
        var ink: ThemeRGB
        switch role {
        case .default:
            fill = tokens.accent.withAlpha(1).mixed(toward: card[0], step)
            ink = tokens.onAccent.withAlpha(1)
        case .destructive where quiet:
            fill = tokens.danger.withAlpha(step * 0.6)
            ink = tokens.danger.withAlpha(1)
        case .destructive where filledDestructive:
            // White on red in every theme, as macOS draws a destructive button (Aziz 2026-11-13: "it must be white on
            // red"; light themes drew black, the ink with more contrast on their lighter red). The red deepens until
            // white reads at 4.5:1 on it; hover and press deepen it a step more.
            ink = Self.white
            fill = Self.deepened(tokens.danger.withAlpha(1), under: ink).mixed(toward: Self.black, step)
        case .destructive:
            fill = tokens.danger.withAlpha((tokens.isDark ? 0.18 : 0.12) + step * 0.4)
            ink = tokens.danger.withAlpha(1)
        case .cancel, .normal:
            // Denser on hover and press, in the same hue (an accent theme's selection is tinted).
            fill = tokens.selectionFill.withAlpha(min(1, tokens.selectionFill.alpha * (1 + step * 3)))
            ink = tokens.textPrimary.withAlpha(1)
        }
        if !isEnabled, let base = card.first {
            fill = fill.alpha < 1 ? fill.withAlpha(fill.alpha * 0.5) : fill.mixed(toward: base, 0.5)
        }
        var surfaces = card.map { fill.composited(over: $0) }
        let translucentTitle = isEnabled && (role == .cancel || role == .normal)
        let roomy = Self.minimumContrast + Self.translucentTitleHeadroom
        if translucentTitle {
            // A translucent gray over grounds no one ink reads on (a mid-tone theme's popover glass over a white and a
            // black page) densifies until one does: Hot Dog Stand's Stop read 4.08:1 in black over the page and its
            // Open Agent Activity 2.66:1 in the gray the passes ended on.
            for _ in 0..<12 where fill.alpha < 1
                && !Self.fits(Self.readable(ink, over: surfaces, minimum: roomy), over: surfaces, minimum: roomy) {
                fill = fill.withAlpha(min(1, fill.alpha + 0.08))
                surfaces = card.map { fill.composited(over: $0) }
            }
        }
        let roomyInk = translucentTitle ? Self.readable(ink, over: surfaces, minimum: roomy) : nil
        if let roomyInk, Self.fits(roomyInk, over: surfaces, minimum: roomy) {
            ink = roomyInk
        } else if isEnabled {
            ink = Self.readable(ink, over: surfaces)
        } else if let under = surfaces.first {
            ink = Self.readable(ink.mixed(toward: under, 0.5), over: surfaces, minimum: Self.disabledMinimumContrast)
        }
        self.fill = fill
        title = ink
        keyHint = isEnabled ? surfaces.first.map { Self.readable(ink.mixed(toward: $0, 0.3), over: surfaces) } ?? ink : ink
        self.surfaces = surfaces
        // The surface the glass card really shows (the scrimmed window), for the focus gap.
        self.card = card.count > 2 ? card[2] : card.first ?? fill.withAlpha(1)
        opaqueCard = card.count > 1 ? card[1] : self.card
        focusRing = Self.readable(tokens.focusRing.composited(over: card.first ?? fill.withAlpha(1)), over: card,
                                  minimum: Self.focusMinimumContrast)
    }

    /// The card a dialog button sits on: the dialog glass's veil over the window under the scrim
    /// (`FloatingGlassStyle.dialog`), the opaque popup surface (Reduce Transparency), and the
    /// scrimmed window itself. Liquid Glass shows little of its veil: on a light theme the real card
    /// measured rgb(223,223,223), the scrimmed window, not the veil estimate (about 241), so an ink
    /// fit only to the estimate read under its floor there (the focus ring, 2.66:1).
    public static func cardSurfaces(_ tokens: ThemeTokens, lift: Double = 0.14) -> [ThemeRGB] {
        let veil = FloatingGlassStyle.dialog.look(isDark: tokens.isDark).veil
        let glass = ThemeRGB(red: veil.white, green: veil.white, blue: veil.white, alpha: veil.alpha)
        let scrimmed = tokens.scrim.composited(over: tokens.windowBackground.withAlpha(1))
        // glass-opaque-allow: a contrast reference only (the card under Reduce Transparency); nothing paints it here
        return [glass.composited(over: scrimmed), tokens.opaqueOverlayFill(lift: lift), scrimmed]
    }

    /// The card a button on a prompt floating over every app sits on (``SurfaceRole/prompt``): its veil, the theme's
    /// glass tint at the prompt's opacity, over the theme's own window, the opaque popup surface (Reduce
    /// Transparency), and the veil over the brightest and the darkest page. No scrim dims what is under the
    /// prompt as one dims a dialog's window, and any app shows through, so its inks are fit over any page.
    public static func promptCardSurfaces(_ tokens: ThemeTokens, lift: Double = 0.14) -> [ThemeRGB] {
        let alpha = FloatingGlassStyle.prompt.look(isDark: tokens.isDark).veil.alpha
        let veil = tokens.glassTint.withAlpha(Double(alpha))
        func glass(over page: ThemeRGB) -> ThemeRGB { veil.composited(over: page) }
        let own = glass(over: tokens.windowBackground.withAlpha(1))
        // glass-opaque-allow: a contrast reference only (the card under Reduce Transparency); nothing paints it here
        return [own, tokens.opaqueOverlayFill(lift: lift), own, glass(over: white), glass(over: black)]
    }

    /// The card a button on a floating menu or popover sits on (``Glass/makeMenuPanel(content:cornerRadius:interactive:)``,
    /// the omnibar's bookmark bubble): the menu glass (the theme's glass tint at the menu level, then the theme veil,
    /// ``GlassMenuMaterial/veil(for:)``) over the theme's own window, the opaque popup surface (Reduce Transparency), and the
    /// glass over the brightest and the darkest page. No scrim dims what is behind a popover as one dims a dialog's
    /// window, so a button's inks are fit over any page that can show through (a1273: the bubble's More… and Remove).
    /// The third surface is the theme's window again: the focus ring's gap sits on the glass the card really shows.
    public static func menuCardSurfaces(_ tokens: ThemeTokens, lift: Double = 0.14) -> [ThemeRGB] {
        let veil = GlassMenuMaterial.veil(for: tokens)
        func glass(over page: ThemeRGB) -> ThemeRGB { GlassMenuMaterial.glass(tokens, veil: veil, over: page) }
        let own = glass(over: tokens.windowBackground.withAlpha(1))
        // glass-opaque-allow: a contrast reference only (the card under Reduce Transparency); nothing paints it here
        return [own, tokens.opaqueOverlayFill(lift: lift), own, glass(over: white), glass(over: black)]
    }

    /// The ground a button sits on outside any card (a Home page, a settings pane, a sheet's own window): the window's
    /// background, and in a see-through window that background over the worst desktop for the theme (white behind a
    /// dark theme, black behind a light one), as the theme's own text is fit. A gray Cancel fit to the dialog card read
    /// 1.65:1 there instead (Hot Dog Stand, NativeControlContrastAuditTests). All three surfaces are that ground: the
    /// focus ring's gap sits on it too.
    public static func windowSurfaces(_ tokens: ThemeTokens) -> [ThemeRGB] {
        let ground = tokens.windowBackground.composited(over: tokens.isDark ? white : black)
        return [ground, ground, ground]
    }

    static let white = ThemeRGB(red: 1, green: 1, blue: 1)
    static let black = ThemeRGB(red: 0, green: 0, blue: 0)

    /// `fill` moved toward black in small steps until `ink` reads on it at ``minimumContrast`` (a few steps at most).
    static func deepened(_ fill: ThemeRGB, under ink: ThemeRGB) -> ThemeRGB {
        var deep = fill
        for _ in 0..<30 where ink.contrast(with: deep) < minimumContrast + 0.05 { deep = deep.mixed(toward: black, 0.04) }
        return deep
    }

    /// Whether `ink` reads at `minimum` on every surface.
    static func fits(_ ink: ThemeRGB, over surfaces: [ThemeRGB], minimum: Double = minimumContrast) -> Bool {
        surfaces.allSatisfy { ink.contrast(with: $0) >= minimum }
    }

    /// `ink` moved toward its pole until it reads at ``minimumContrast`` on every surface. A move for
    /// one surface can lower the contrast on another, so the passes repeat until all read (a few at
    /// most: the card's surfaces are near one another).
    ///
    /// When no ink reads on every surface (a mid-tone theme's popover glass over both a white and a black page), the
    /// passes stop on a gray between the poles that reads on none: Hot Dog Stand's Stop read 3.68:1 and Open Agent
    /// Activity 2.66:1 on its red glass. Then the ink is the one of that gray, white and black that reads on the most
    /// surfaces, and of those the one whose worst contrast is highest.
    static func readable(_ ink: ThemeRGB, over surfaces: [ThemeRGB], minimum: Double = minimumContrast) -> ThemeRGB {
        let target = minimum + 0.05
        var fitted = ink
        for _ in 0..<4 where !surfaces.allSatisfy({ fitted.contrast(with: $0) >= target }) {
            fitted = surfaces.reduce(fitted) { ThemeTokens.readable($0, over: $1, minimum: target) }
        }
        guard !surfaces.allSatisfy({ fitted.contrast(with: $0) >= target }) else { return fitted }
        func score(_ candidate: ThemeRGB) -> (reads: Int, worst: Double) {
            (surfaces.filter { candidate.contrast(with: $0) >= target }.count,
             surfaces.map { candidate.contrast(with: $0) }.min() ?? 0)
        }
        return [fitted, white, black].max { score($0) < score($1) } ?? fitted
    }
}
