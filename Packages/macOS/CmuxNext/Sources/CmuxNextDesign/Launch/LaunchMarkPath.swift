public import CoreGraphics

/// The cmux chevron (`web/public/cmux-icon.svg`, the iOS sign-in mark) as a
/// path, so the launch mark draws natively before any asset or webview
/// loads.
extension CGPath {
    /// The chevron's corners in the SVG's 256-unit box (y down).
    private static let launchMarkPoints: [CGPoint] = [
        CGPoint(x: 91, y: 65), CGPoint(x: 179, y: 128), CGPoint(x: 91, y: 191),
        CGPoint(x: 91, y: 151), CGPoint(x: 139, y: 128), CGPoint(x: 91, y: 105),
    ]
    private static let launchMarkBounds = CGRect(x: 91, y: 65, width: 88, height: 126)

    /// Width over height of the chevron.
    public static let launchMarkAspect: CGFloat = launchMarkBounds.width / launchMarkBounds.height

    /// The chevron fitted and centered in `rect` (y up, as layers draw).
    public static func launchMark(in rect: CGRect) -> CGPath {
        let box = launchMarkBounds
        let scale = min(rect.width / box.width, rect.height / box.height)
        let origin = CGPoint(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
        let path = CGMutablePath()
        path.addLines(between: launchMarkPoints.map {
            CGPoint(x: origin.x + ($0.x - box.minX) * scale, y: origin.y + (box.maxY - $0.y) * scale)
        })
        path.closeSubpath()
        return path
    }
}
