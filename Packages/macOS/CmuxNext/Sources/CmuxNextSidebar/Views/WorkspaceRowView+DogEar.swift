import AppKit
import CmuxNextDesign

extension WorkspaceRowView {
    /// The hover dog-ear (Leo 2026-10-21): the close on a row that can close, else the menu,
    /// folded over the top-right corner of `full` (the row's whole frame, a status block
    /// included). Both take that corner as their frame, so the menu opens under it from
    /// VoiceOver's custom action too. Hidden (not only clear) while they do not show.
    func layoutDogEar(full: NSRect, showClose: Bool, showMenu: Bool, fades: Bool) {
        let side = SidebarStyle.dogEarSide
        let corner = NSRect(x: full.maxX - side, y: full.minY, width: side, height: side)
        let radius = layer?.cornerRadius ?? SidebarStyle.rowCornerRadius
        for (ear, shown) in [(closeButton, showClose), (moreButton, showMenu)] {
            ear.frame = corner
            ear.cornerRadius = radius
            setHoverShown(ear, shown, fades: fades)
        }
    }
}
