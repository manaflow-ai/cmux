public import CmuxTheme
public import CmuxNextDesignTokens

/// The address bar's fills, from the terminal theme (cx-d0d.101): the bar
/// is a tonal step of the theme's text color over the toolbar, stronger on
/// hover. While editing, and as the top of the suggestion card, it is the
/// opaque `card` color, as the card is: the background (light) or a 0.12
/// step toward the text (dark), the reference's results surface (chief
/// 2026-10-15: the omnibar matches it; other overlays keep the popup surface).
///
/// Steps are fractions from the background toward the text, read off 2x
/// captures of the reference browser's default theme (light and dark,
/// idle, hover, focused, suggestions; the table is in the bead). Over an
/// opaque toolbar of the background color each fill composites to exactly
/// `background.mixed(toward: text, step)`.
///
/// See-through windows (`background-opacity` below 1, a background image,
/// glass): the bar keeps the window's transparency. Its fill is the
/// background at `coverage` with the text-color step over it, so the
/// toolbar and the bar stay one material and the bar only shifts the tone.
/// `coverage` is the user's `browser.omnibar.backgroundOpacity`, raised to
/// the least value at which the primary text keeps 4.5:1 over the bar laid
/// on pure black and on pure white (the worst a desktop can be behind the
/// window), so the text reads over anything without a muddy slab. With a
/// toolbar color of its own (`appearance.surfaces.browserChrome`) the bar
/// is the same step over the theme background at `coverage`.
public nonisolated struct AddressBarSurface: Hashable, Sendable {
    public enum State: String, Sendable, CaseIterable {
        case rest, hover
    }

    /// Steps toward the text color, dark then light theme.
    static func step(_ state: State, isDark: Bool) -> Double {
        switch state {
        case .rest: isDark ? 0.10 : 0.07
        case .hover: isDark ? 0.245 : 0.12
        }
    }

    /// `state`'s step for this theme, eased back (1% at a time) until the
    /// primary text keeps 4.5:1 on the opaque fill: a low-contrast theme
    /// gets a softer hover rather than unreadable text.
    func readableStep(_ state: State) -> Double {
        var step = Self.step(state, isDark: isDark)
        while step > 0, text.contrast(with: background.mixed(toward: text, step)) < ThemeTokens.minimumTextContrast {
            step = max(step - 0.01, 0)
        }
        return step
    }

    /// The opaque card step toward the text, dark then light.
    static func cardStep(isDark: Bool) -> Double { isDark ? 0.12 : 0 }

    /// The selected suggestion row over the card, with a neutral selection.
    static func rowSelectedAlpha(isDark: Bool) -> Double { isDark ? 0.105 : 0.05 }

    public let background: ThemeRGB
    public let text: ThemeRGB
    public let isDark: Bool
    /// The window's own tint opacity behind the toolbar (1: opaque window).
    public let windowOpacity: Double

    public init(_ tokens: ThemeTokens, windowOpacity: Double) {
        background = tokens.surfaceBackground.withAlpha(1)
        text = tokens.textPrimary.withAlpha(1)
        isDark = tokens.isDark
        self.windowOpacity = min(max(windowOpacity, 0), 1)
    }

    /// The bar's fill in `state` at the user's `coverage` (0...1).
    public func fill(_ state: State, coverage: Double) -> ThemeRGB {
        layered(step: readableStep(state), coverage: resolvedCoverage(coverage))
    }

    /// The opaque suggestion card, and the bar while editing or topping it.
    public var card: ThemeRGB { background.mixed(toward: text, Self.cardStep(isDark: isDark)) }

    /// A selected suggestion row over `card`, when the theme's selection is neutral.
    public var rowSelected: ThemeRGB { text.withAlpha(Self.rowSelectedAlpha(isDark: isDark)) }

    /// `coverage` raised to the legibility floor of every state (rest and
    /// hover); any value in an opaque window.
    public func resolvedCoverage(_ coverage: Double) -> Double {
        let requested = coverage.isFinite ? min(max(coverage, 0), 1) : 0
        guard windowOpacity < 1 else { return requested }
        let steps = State.allCases.map(readableStep)
        func readable(_ candidate: Double) -> Bool {
            steps.allSatisfy { worstContrast(layered(step: $0, coverage: candidate)) >= ThemeTokens.minimumTextContrast }
        }
        if readable(requested) { return requested }
        for percent in Int((requested * 100 - 1e-9).rounded(.up))...100 where readable(Double(percent) / 100) {
            return Double(percent) / 100
        }
        return 1
    }

    /// The background at `coverage`, then the text color at `step`, as one color.
    func layered(step: Double, coverage: Double) -> ThemeRGB {
        let alpha = 1 - (1 - step) * (1 - coverage)
        guard alpha > 0 else { return background.withAlpha(0) }
        func channel(_ text: Double, _ background: Double) -> Double { (step * text + (1 - step) * coverage * background) / alpha }
        return ThemeRGB(red: channel(text.red, background.red), green: channel(text.green, background.green),
                        blue: channel(text.blue, background.blue), alpha: alpha)
    }

    /// The text's contrast over `fill` on the window tint, over pure black and
    /// pure white behind the window (the two ends of what a desktop can be; a
    /// mid-tone between them is in practice no worse once both ends pass).
    func worstContrast(_ fill: ThemeRGB) -> Double {
        [ThemeRGB(hex: 0x000000), ThemeRGB(hex: 0xFFFFFF)].map { desktop in
            let window = background.withAlpha(windowOpacity).composited(over: desktop)
            return text.contrast(with: fill.composited(over: window))
        }.min() ?? 1
    }
}

public extension Palette {
    /// The address bar surface of the active theme scope and its window.
    @MainActor static var addressBar: AddressBarSurface {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let backdrop = WindowBackdrop.current(tokens, reduceTransparency: ReduceTransparency.shared.isEnabled)
        return AddressBarSurface(tokens, windowOpacity: backdrop.tintOpacity)
    }

    /// Whether the theme's selection is an accent color (`appearance.accent`), not the neutral one.
    @MainActor static var selectionIsAccent: Bool {
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        return tokens.accent != tokens.textPrimary
    }
}
