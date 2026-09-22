import Foundation

/// The source row, submenu, and narrow diagonal path connecting their edges.
struct CmuxSubmenuHoverRegion {
    let source: CGRect
    let submenu: CGRect

    func contains(_ point: CGPoint) -> Bool {
        if source.contains(point) || submenu.contains(point) { return true }
        let sourceX: CGFloat
        let submenuX: CGFloat
        if submenu.minX >= source.maxX {
            sourceX = source.maxX
            submenuX = submenu.minX
        } else if submenu.maxX <= source.minX {
            sourceX = source.minX
            submenuX = submenu.maxX
        } else {
            return false
        }
        guard sourceX != submenuX else { return false }
        let progress = (point.x - sourceX) / (submenuX - sourceX)
        guard (0...1).contains(progress) else { return false }
        let lowerY = source.minY + (submenu.minY - source.minY) * progress
        let upperY = source.maxY + (submenu.maxY - source.maxY) * progress
        return point.y >= lowerY && point.y <= upperY
    }
}
