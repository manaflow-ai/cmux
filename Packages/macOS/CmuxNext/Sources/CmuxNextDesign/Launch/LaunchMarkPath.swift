public import CoreGraphics

/// The cmux chevron (`web/public/cmux-icon.svg`, the iOS sign-in mark) as a
/// path, so the launch mark draws natively before any asset or webview
/// loads.
public nonisolated enum LaunchMarkPath {
    /// The chevron's corners in the SVG's 256-unit box (y down).
    private static let svgPoints: [CGPoint] = [
        CGPoint(x: 91, y: 65), CGPoint(x: 179, y: 128), CGPoint(x: 91, y: 191),
        CGPoint(x: 91, y: 151), CGPoint(x: 139, y: 128), CGPoint(x: 91, y: 105),
    ]
    private static let svgBounds = CGRect(x: 91, y: 65, width: 88, height: 126)

    /// Width over height of the chevron.
    public static let aspect: CGFloat = svgBounds.width / svgBounds.height

    /// The chevron fitted and centered in `rect` (y up, as layers draw).
    public static func path(in rect: CGRect) -> CGPath {
        let scale = min(rect.width / svgBounds.width, rect.height / svgBounds.height)
        let origin = CGPoint(x: rect.midX - svgBounds.width * scale / 2, y: rect.midY - svgBounds.height * scale / 2)
        let path = CGMutablePath()
        path.addLines(between: svgPoints.map {
            CGPoint(x: origin.x + ($0.x - svgBounds.minX) * scale, y: origin.y + (svgBounds.maxY - $0.y) * scale)
        })
        path.closeSubpath()
        return path
    }
}
