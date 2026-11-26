public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// Subtle Tone's frame in the theme's ink (``FrameTone``): what the shade around the card, the flush corner's
/// wedges, a lower strip's toned row and every tab state on the frame draw.
extension Metrics {
    /// The theme-derived frame share for `tokens` (``FrameTone/share(_:)``): at most 26 OKLCH conversions, no cache.
    static func frameShare(_ tokens: ThemeTokens) -> Double { FrameTone.share(tokens) }

    /// The tokens a theme-free caller paints with: the active scope's, else the app's.
    static var activeTokens: ThemeTokens { ThemeContext.active ?? ThemeScope.app.tokens }

    /// Whether the frame around the card is Subtle Tone's ink frame: the flush corner on the curved main pane with
    /// `appearance.titleAreaTone` Subtle Tone. One Color and the other chrome styles keep their own shade.
    public static var drawsInkFrame: Bool {
        mainPaneCurved && CornerFlush.current.isOn && DesignSettings.shared.titleAreaTone == .subtleTone
    }

    /// Subtle Tone's frame alpha (ink over the card): the theme's least separating share times
    /// `appearance.titleAreaContrast`; nil when ``drawsInkFrame`` is off. A caller with only `isDark` gets the active
    /// scope's tokens when they match it, else the frame rung.
    public static func inkFrameShade(isDark: Bool, tokens: ThemeTokens? = nil) -> CGFloat? {
        guard drawsInkFrame else { return nil }
        let theme = tokens ?? activeTokens
        let share = theme.isDark == isDark ? frameShare(theme) : FrameTone.frameRung
        return min(1, max(0, CGFloat(share) * DesignSettings.shared.titleAreaContrast))
    }

    /// The color the chrome's frame is washed in, opaque (its alpha is ``mainPaneChromeShade(isDark:)``): the theme's
    /// ink under ``drawsInkFrame``, else black, as the shade always was.
    public static func chromeFrameInk(_ tokens: ThemeTokens? = nil) -> NSColor {
        drawsInkFrame ? (tokens ?? activeTokens).textPrimary.withAlpha(1).nsColor : .black
    }

    /// A tab's state on Subtle Tone's frame, one theme step over its ground (the frame, at
    /// ``inkFrameShade(isDark:tokens:)``): hover and multi-selection one step, a press two (``FrameTone``). Each
    /// step is the theme's own frame share, so a state reads as far from the frame as the frame does from the card,
    /// on every theme and over glass alike. nil off the ink frame or under the least shade a folder tab reads at,
    /// where the tokens' own fills apply.
    public struct FrameStateFills: Sendable {
        public let hover: NSColor
        public let pressed: NSColor
    }

    public static func frameStateFills(_ tokens: ThemeTokens? = nil) -> FrameStateFills? {
        let theme = tokens ?? activeTokens
        guard let under = inkFrameShade(isDark: theme.isDark, tokens: theme), under >= folderTabMinimumShade else { return nil }
        let step = frameShare(theme), ground = Double(under)
        let ink = theme.textPrimary.withAlpha(1)
        func fill(_ steps: Double) -> NSColor {
            ink.withAlpha(FrameTone.wash(rung: ground + step * steps, over: ground)).nsColor
        }
        return FrameStateFills(hover: fill(1), pressed: fill(2))
    }

    /// A dragged tab on Subtle Tone's frame: the card's own surface, lifted (solid in an opaque window, the floating
    /// glass over a see-through one, ``WindowBackdrop/dragLiftFill(_:)``), so the tab picked up is the same material
    /// as the folder it left. nil off the ink frame.
    public static func frameLiftSurface(_ tokens: ThemeTokens? = nil) -> NSColor? {
        guard drawsInkFrame else { return nil }
        return (tokens ?? activeTokens).surfaceBackground.withAlpha(1).nsColor
    }
}
