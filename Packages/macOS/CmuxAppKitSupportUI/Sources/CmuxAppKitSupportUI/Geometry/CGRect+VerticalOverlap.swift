public import AppKit

extension CGRect {
    /// The height of the vertical span shared by `self` and `other`, clamped to
    /// be non-negative. Returns 0 when the rectangles do not overlap on the
    /// y-axis. Used to decide whether a docked inspector and a candidate sibling
    /// view occupy the same vertical band before pairing them.
    public func verticalOverlap(with other: CGRect) -> CGFloat {
        max(0, min(maxY, other.maxY) - max(minY, other.minY))
    }
}
