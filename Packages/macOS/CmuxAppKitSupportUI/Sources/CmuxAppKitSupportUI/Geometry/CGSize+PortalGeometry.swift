public import AppKit

extension CGSize {
    /// Whether `self` and `other` are equal within `epsilon` on both the width
    /// and height. Callers pass the tolerance explicitly so each comparison site
    /// keeps its own intended slack.
    public func isApproximatelyEqual(to other: CGSize, epsilon: CGFloat) -> Bool {
        abs(width - other.width) <= epsilon &&
            abs(height - other.height) <= epsilon
    }
}
