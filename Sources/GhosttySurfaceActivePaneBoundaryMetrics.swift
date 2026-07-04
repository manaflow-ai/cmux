import AppKit

enum GhosttySurfaceActivePaneBoundaryMetrics {
    static let lineWidth: CGFloat = 2
    static let inset: CGFloat = lineWidth / 2
}

extension CGRect {
    func ghosttyActivePaneBoundaryPath(includesBottomEdge: Bool) -> CGPath? {
        let inset = GhosttySurfaceActivePaneBoundaryMetrics.inset
        guard width > inset * 2, height > inset * 2 else { return nil }
        let rect = insetBy(dx: inset, dy: inset)
        guard !includesBottomEdge else {
            return CGPath(rect: rect, transform: nil)
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
