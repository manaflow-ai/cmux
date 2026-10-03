import CoreGraphics

/// Places the single-slider appearance peek at the bottom of the real window.
enum AppearanceTunerPlacement {
    static let width: CGFloat = 360
    static let height: CGFloat = 122
    static let gap: CGFloat = 16

    static func frame(content: CGRect) -> CGRect {
        let inner = content.insetBy(dx: gap, dy: gap)
        let width = min(Self.width, inner.width)
        let height = min(Self.height, inner.height)
        return CGRect(x: inner.midX - width / 2, y: inner.minY, width: width, height: height)
    }
}
