public import AppKit

/// What a drag preview stands on: a lifted tab in its strip and the drag ghost that follows the
/// pointer between windows (a lifted sidebar row is always the overlay glass, `DragLiftView`).
/// In a translucent window (any material but opaque) both are glass over the window's art and
/// tint, like the window they came from; only an opaque window (or Reduce Transparency) keeps the
/// solid theme card. Before this, both painted a flat theme fill, so a tab turned from glass to a
/// solid block the moment it was picked up.
public extension WindowBackdrop {
    /// How much of the solid lift fill a lifted tab keeps over the window's own tint: enough that
    /// the tabs sliding under it stay quiet, little enough that the art reads through.
    static let dragLiftCoverage = 0.6

    /// The backdrop a drag preview drawn in `scope` stands on: the window's (the same art, tuning
    /// and tint `WindowRootView` paints), with the user's Reduce Transparency setting. Read in
    /// the scope the preview is lifted from: a workspace that pins its own background, or none,
    /// differs from the app's.
    @MainActor static func dragPreview(_ scope: ThemeScope,
                                       reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) -> WindowBackdrop {
        WindowBackdrop(scope.tokens, reduceTransparency: reduceTransparency, art: scope.backdropArt,
                       selection: scope.backdropSelection, tuning: scope.appearanceTuning,
                       tintOpacity: scope.backdropTintOpacity)
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
