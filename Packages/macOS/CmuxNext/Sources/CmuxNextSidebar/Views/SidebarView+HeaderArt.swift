import AppKit
import CmuxNextDesign

/// The theme's sidebar header picture (`appearance.sidebarHeader.*`, `ThemeFlourishes.sidebarHeader`):
/// a rounded card under the titlebar row and above the list, which moves down by its height. The
/// picture comes from the shared decode cache (`BackdropPictureView`). No picture: no view at all,
/// and the sidebar lays out as it always did.
extension SidebarViewComponents {
    /// Shows `selection` (nil removes the view), from `render` when the setting changes.
    func showHeaderArt(_ selection: BackdropSelection?) {
        needsLayout = true
        guard let selection else {
            headerArt?.removeFromSuperview()
            headerArt = nil
            return
        }
        let view = headerArt ?? BackdropPictureView()
        if headerArt == nil {
            addSubview(view)
            headerArt = view
        }
        view.selection = selection
    }

    /// Frames the picture under the titlebar row at `top` and returns how far it pushes the list
    /// down: 0 without a picture.
    func layoutHeaderArt(top: CGFloat, width: CGFloat) -> CGFloat {
        guard let headerArt else { return 0 }
        let inset = Metrics.space2
        let cardWidth = max(0, width - 2 * inset)
        let height = Self.headerArtHeight(width: cardWidth)
        headerArt.frame = NSRect(x: inset, y: top, width: cardWidth, height: height)
        headerArt.cornerRadius = Metrics.panelCornerRadius
        return height + inset
    }

    /// The picture's height for a card `width` wide: a wide banner, at least 64 pt and at most 140 pt.
    static func headerArtHeight(width: CGFloat) -> CGFloat {
        min(max((width * 0.36).rounded(), 64), 140)
    }
}
