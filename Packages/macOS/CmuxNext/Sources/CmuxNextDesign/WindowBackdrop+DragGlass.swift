public import AppKit

/// What a drag preview stands on: a lifted tab in its strip, a lifted sidebar row, the drag
/// ghost that follows the pointer between windows. In a translucent window (any material but
/// opaque) every one of them is glass over the window's art and tint, like the window it came
/// from; only an opaque window (or Reduce Transparency) keeps the solid theme card. Before this,
/// each painted a flat theme fill, so a tab or workspace turned from glass to a solid block the
/// moment it was picked up.
public extension WindowBackdrop {
    /// How much of the solid lift fill a lifted tab keeps over the window's own tint: enough that
    /// the tabs sliding under it stay quiet, little enough that the art reads through.
    static let dragLiftCoverage = 0.6

    /// The backdrop a drag preview drawn in `tokens` stands on: the window's, with the user's
    /// Reduce Transparency setting.
    @MainActor static func dragPreview(_ tokens: ThemeTokens,
                                       reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) -> WindowBackdrop {
        current(tokens, reduceTransparency: reduceTransparency)
    }

    /// Whether drag previews over this backdrop draw on glass.
    var dragsOnGlass: Bool { !isOpaque }

    /// The lift fill's alpha over this backdrop's tint: between the tint and solid
    /// (``dragLiftCoverage``), so a lifted tab reads as a thicker piece of the same glass.
    var dragLiftAlpha: CGFloat {
        let tint = min(max(tintOpacity, 0), 1)
        return CGFloat(tint + (1 - tint) * Self.dragLiftCoverage)
    }

    /// The fill of a lifted tab or a stacked card: `color` solid in an opaque window, else at
    /// ``dragLiftAlpha``.
    func dragLiftFill(_ color: NSColor) -> NSColor {
        color.withAlphaComponent(dragsOnGlass ? dragLiftAlpha : 1)
    }

    /// The card a drag image is rendered on: `color` in an opaque window; none over glass, where
    /// the preview's own glass panel is the card.
    func dragCardFill(_ color: NSColor) -> NSColor? {
        dragsOnGlass ? nil : color.withAlphaComponent(1)
    }
}
