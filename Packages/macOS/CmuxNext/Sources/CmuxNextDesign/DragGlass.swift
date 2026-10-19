public import AppKit

/// What a drag preview stands on: a lifted tab in its strip, a lifted sidebar row, the drag
/// ghost that follows the pointer between windows. In a translucent window (any material but
/// opaque, ``WindowBackdrop``) every one of them is glass over the window's art and tint, like
/// the window it came from; only an opaque window (or Reduce Transparency) keeps the solid theme
/// card. Before this, each painted a flat theme fill, so a tab or workspace turned from glass to
/// a solid block the moment it was picked up.
public enum DragGlass {
    /// How much of the solid lift fill a lifted tab keeps over the window's own tint: enough that
    /// the tabs sliding under it stay quiet, little enough that the art reads through.
    public static let liftCoverage = 0.6

    /// The backdrop a preview drawn in `tokens` stands on: the window's, with the user's Reduce
    /// Transparency setting.
    @MainActor public static func backdrop(_ tokens: ThemeTokens,
                                           reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) -> WindowBackdrop {
        WindowBackdrop.current(tokens, reduceTransparency: reduceTransparency)
    }

    /// Whether previews over `backdrop` draw on glass.
    public static func isGlass(_ backdrop: WindowBackdrop) -> Bool { !backdrop.isOpaque }

    /// The fill of a lifted tab or a stacked card: `color` solid in an opaque window, else at an
    /// alpha between the window's tint and solid (``liftCoverage``), so it reads as a thicker
    /// piece of the same glass.
    public static func liftFill(_ color: NSColor, over backdrop: WindowBackdrop) -> NSColor {
        guard isGlass(backdrop) else { return color.withAlphaComponent(1) }
        return color.withAlphaComponent(liftAlpha(tint: backdrop.tintOpacity))
    }

    /// The lift fill's alpha over a window tinted at `tint`.
    public static func liftAlpha(tint: Double) -> CGFloat {
        let tint = min(max(tint, 0), 1)
        return CGFloat(tint + (1 - tint) * liftCoverage)
    }

    /// The card a drag image is rendered on: `color` in an opaque window; none over glass, where
    /// the preview's own glass panel is the card.
    public static func cardFill(_ color: NSColor, over backdrop: WindowBackdrop) -> NSColor? {
        isGlass(backdrop) ? nil : color.withAlphaComponent(1)
    }
}
