import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// The hover action on the top-right corner of `full` (the row's whole frame, a status block
    /// included): the close on a row that can close, else the menu (Leo 2026-10-21). While one shows,
    /// the row's fill leaves its corner out (`SidebarCloseNotch`, Leo 2026-10-22), and both take that
    /// cut as their frame (`SidebarCloseNotch.cutFrame`), so the menu opens under it from VoiceOver's
    /// custom action too. Hidden (not only clear) while they do not show. The look comes from
    /// configure (`closeNotchLook`, watched by `SidebarTunablesWatch`).
    func layoutDogEar(full: NSRect, showClose: Bool, showMenu: Bool, fades: Bool) {
        let look = closeNotchLook
        let side = look.side(dogEar: SidebarStyle.dogEarSide)
        let radius = look.cornerRadius(rowRadius: layer?.cornerRadius ?? SidebarStyle.rowCornerRadius)
        let corner = SidebarCloseNotch.cutFrame(in: full, side: side, radius: radius)
        // The drawn fill in each button's own coordinates: a button takes exactly the clicks the fill
        // leaves out, the cut's fillets past its square included.
        var shift = CGAffineTransform(translationX: -corner.minX, y: -corner.minY)
        let fill = SidebarCloseNotch.fillPath(in: full, side: side, radius: radius).copy(using: &shift)
        for (ear, shown) in [(closeButton, showClose), (moreButton, showMenu)] {
            ear.frame = corner
            ear.rowFill = fill
            setHoverShown(ear, shown, fades: fades)
        }
        let notch = showClose || showMenu ? look : nil
        if notch != closeNotch || notch != nil {
            closeNotch = notch
            needsDisplay = true
        }
    }

    /// The fill's shape while the close's corner is cut out of it (and the cut's hairline in that
    /// look); nil while the row fills its whole shape.
    var notchedFill: (shape: CGPath, edge: CGPath?)? {
        guard let look = closeNotch else { return nil }
        let rect = layoutBounds
        let side = look.side(dogEar: SidebarStyle.dogEarSide)
        let radius = look.cornerRadius(rowRadius: layer?.cornerRadius ?? SidebarStyle.rowCornerRadius)
        return (SidebarCloseNotch.fillPath(in: rect, side: side, radius: radius),
                look == .hairline ? SidebarCloseNotch.edgePath(in: rect, side: side, radius: radius) : nil)
    }

    /// The row's end controls that can sit under the corner on a short row (the tabs chevron, the
    /// session tree's fold, the audio button) draw over the close, as they take the clicks there
    /// (`interactiveSubviews` hit-tests the corner's buttons last): what shows on top is what a
    /// click presses.
    func raiseControlsOverDogEar() {
        for control in [disclosureButton, treeFoldButton, audioButton] {
            control.layer?.zPosition = SidebarDogEarButton.zPosition + 1
        }
    }
}
