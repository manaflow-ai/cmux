import AppKit

extension CGRect {
    /// The height of the vertical span shared by `self` and `other`, clamped to
    /// be non-negative (0 when the rectangles do not overlap on the y-axis).
    /// Used by `HostedInspectorDividerFinder` to decide whether a docked
    /// inspector and a candidate sibling page view occupy the same vertical band
    /// before pairing them.
    ///
    /// Kept package-internal so it does not collide with the public
    /// `CGRect.verticalOverlap(with:)` that `CmuxAppKitSupportUI` exposes to the
    /// app target, which the browser domain package cannot depend on upward.
    func verticalOverlap(with other: CGRect) -> CGFloat {
        max(0, min(maxY, other.maxY) - max(minY, other.minY))
    }
}
