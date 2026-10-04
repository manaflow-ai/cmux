import AppKit

extension SidebarRegionView {
    var displayedSections: [LayoutSection] { [] }
    func beginDrag(_ subject: SidebarRegionDragSubject, at point: NSPoint) {}
    func updateDrag(to point: NSPoint) {}
    func finishDrag() {}
}
