import AppKit

/// What a page's glass lenses of a backdrop (plans/cmux-next/glass-lens-DESIGN.md): the still art
/// as drawn, before its blur, where it lies, its blur and the wash over it.
extension WindowMaterialView {
    /// The art pages may refract now: nil under the solid sheet, without art, under a moving
    /// wallpaper, or where the desktop shows through more than a little of the art.
    var glassStill: NSImage? {
        guard !isHidden, !hidesArt, !artView.isHidden, !showsVideo, Self.refractsArt(opacity: artOpacity) else { return nil }
        return artImage
    }

    /// Whether pages refract art drawn at `opacity`: opaque art, and Window Glass's (Clear Glass over
    /// art), which the desktop shows through only a little. Under Window Glass the art is what the
    /// page's glass shows, not plain blur (Leo, 2026-11-07: "the point is to have the art show through
    /// and be shown nicely").
    static func refractsArt(opacity: Float) -> Bool {
        opacity >= Float(WindowBackdrop.windowGlassArtOpacity) - 0.001
    }

    /// The art layer's frame in window coordinates; its image is aspect-filled into it.
    var glassArtFrame: CGRect { artView.convert(artView.bounds, to: nil) }

    /// Tells the pages lensing this backdrop that its art, blur or tint may have changed.
    func noteGlassSourceChange() {
        for feed in glassFeeds.allObjects { feed.setNeedsUpdate() }
    }

    /// The backdrop drawn behind `view`: the nearest one under an ancestor's content (a pane's own
    /// art, `appearance.paneBackgrounds` perPane), else the window's. Nil when none shows.
    static func glassBackdrop(behind view: NSView) -> WindowMaterialView? {
        var child = view
        while let parent = child.superview {
            if let backdrop = parent as? WindowMaterialView { return backdrop.isHidden ? nil : backdrop }
            // A sibling below the branch that holds `view` draws behind it.
            if let index = parent.subviews.firstIndex(where: { $0 === child }),
               let backdrop = parent.subviews[..<index].last(where: { ($0 as? WindowMaterialView)?.isHidden == false }) {
                return backdrop as? WindowMaterialView
            }
            child = parent
        }
        return nil
    }
}
