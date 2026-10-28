public import CmuxTheme
public import CoreGraphics

/// How unfocused panes dim, from the Ghostty config's
/// `unfocused-split-opacity` and `unfocused-split-fill` (R93): a veil of
/// `fill` at `amount` over each unfocused pane while a screen has more
/// than one, as Ghostty.app draws over an unfocused split. The App fills
/// `DesignSettings.unfocusedPaneDim` after every config load.
public nonisolated struct UnfocusedPaneDim: Hashable, Sendable {
    /// The veil's opacity: `1 - unfocused-split-opacity`; 0 is no dim.
    public var amount: CGFloat
    /// `unfocused-split-fill`; nil is the theme background, as in Ghostty.
    public var fill: ThemeRGB?

    public init(amount: CGFloat = 0, fill: ThemeRGB? = nil) {
        self.amount = min(max(amount, 0), 1)
        self.fill = fill
    }

    /// The dim for a Ghostty `unfocused-split-opacity` (0.15...1 after
    /// Ghostty's clamp).
    public init(unfocusedSplitOpacity opacity: Double, fill: ThemeRGB?) {
        self.init(amount: CGFloat(1 - opacity), fill: fill)
    }
}
