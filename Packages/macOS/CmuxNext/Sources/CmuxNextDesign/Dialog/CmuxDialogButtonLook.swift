public import CmuxNextDesignTokens

/// The colors one dialog button draws in one theme (``CmuxDialogButtonView``), every ink at least
/// WCAG AA (4.5:1) on what is under it:
/// - default (Return): the theme's solid accent fill (the primary text color unless
///   `appearance.accent` names a hue) with its on-accent ink, as the web pages' primary button
///   draws, so the button Return presses reads first at a glance. It was a gray 3 to 4% denser
///   than Cancel's.
/// - destructive: a solid danger fill with ink fit to 4.5:1 on it, as the web pages' `.danger`
///   button. `filledDestructive: false` gives the tinted alternative (the danger ink on a faint danger
///   wash, lifted to 4.5:1 over the card), kept for the design call (manaflow-ai/cmux#13742). The theme's `danger` is fit only to
///   3:1 (a mark's floor): over the glass it measured 2.1:1 (debug.dialog_strip, 2026-10-28).
/// - cancel and normal: the selection fill (gray, or the accent's tint in an accent theme), a step
///   above the hover fill they had, so each reads as a button on the glass.
///
/// A solid fill carries its own contrast whatever shows through the glass; a translucent one is
/// fit over ``cardSurfaces(_:)``.
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

    public init(role: CmuxDialogButton.Role, tokens: ThemeTokens, state: State = .rest, filledDestructive: Bool = true,
                card: [ThemeRGB]? = nil) {
        let card = card ?? Self.cardSurfaces(tokens)
        // Hover and pressed move a solid fill toward the card a little, a translucent one up a step.
        let step = switch state { case .rest: 0.0; case .hover: 0.1; case .pressed: 0.2 }
        let fill: ThemeRGB
        var ink: ThemeRGB
        switch role {
        case .default:
            fill = tokens.accent.withAlpha(1).mixed(toward: card[0], step)
            ink = tokens.onAccent.withAlpha(1)
        case .destructive where filledDestructive:
            fill = tokens.danger.withAlpha(1).mixed(toward: card[0], step)
            ink = tokens.onAccent.withAlpha(1).contrast(with: fill) >= tokens.textPrimary.contrast(with: fill)
                ? tokens.onAccent.withAlpha(1) : tokens.textPrimary.withAlpha(1)
        case .destructive:
            fill = tokens.danger.withAlpha((tokens.isDark ? 0.18 : 0.12) + step * 0.4)
            ink = tokens.danger.withAlpha(1)
        case .cancel, .normal:
            // Denser on hover and press, in the same hue (an accent theme's selection is tinted).
            fill = tokens.selectionFill.withAlpha(min(1, tokens.selectionFill.alpha * (1 + step * 3)))
            ink = tokens.textPrimary.withAlpha(1)
        }
        let surfaces = card.map { fill.composited(over: $0) }
        ink = Self.readable(ink, over: surfaces)
        self.fill = fill
        title = ink
        keyHint = surfaces.first.map { Self.readable(ink.mixed(toward: $0, 0.3), over: surfaces) } ?? ink
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

    /// `ink` moved toward its pole until it reads at ``minimumContrast`` on every surface. A move for
    /// one surface can lower the contrast on another, so the passes repeat until all read (a few at
    /// most: the card's surfaces are near one another).
    static func readable(_ ink: ThemeRGB, over surfaces: [ThemeRGB], minimum: Double = minimumContrast) -> ThemeRGB {
        let target = minimum + 0.05
        var fitted = ink
        for _ in 0..<4 where !surfaces.allSatisfy({ fitted.contrast(with: $0) >= target }) {
            fitted = surfaces.reduce(fitted) { ThemeTokens.readable($0, over: $1, minimum: target) }
        }
        return fitted
    }
}
