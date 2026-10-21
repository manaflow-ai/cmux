import AppKit

/// What a page's glass lenses of a backdrop (plans/cmux-next/glass-lens-DESIGN.md): the still art
/// as drawn, before its blur, where it lies, its blur and the wash over it.
extension WindowMaterialView {
    /// The art pages may refract now: nil under the solid sheet, without art, under a moving
    /// wallpaper, or where the desktop shows through the art (Clear Glass lowers its opacity).
    var glassStill: NSImage? {
        guard !isHidden, !hidesArt, !artView.isHidden, !showsVideo, artOpacity >= 0.98 else { return nil }
        return artImage
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
