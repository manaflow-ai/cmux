package import CCmuxMotionFFI
public import CoreGraphics

extension CmuxHoverRect {
    /// `rect`'s origin and size as stored (cmux-motion reads the standardized edges itself).
    package nonisolated init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    /// The rect as Core Graphics stores it.
    package nonisolated var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

extension CmuxHoverPoint {
    package nonisolated init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }
}
