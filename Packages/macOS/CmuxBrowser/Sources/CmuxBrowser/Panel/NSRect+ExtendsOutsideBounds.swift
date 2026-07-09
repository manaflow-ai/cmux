public import Foundation

extension NSRect {
    /// Whether this rect pokes outside `bounds` on any edge by more than
    /// `epsilon`, i.e. its min edges fall short of, or its max edges exceed, the
    /// corresponding edges of `bounds` past the tolerance.
    ///
    /// Used by the browser window portal to decide whether a hosted page's
    /// `WKWebView` frame has overflowed its container (the symptom of a
    /// bottom-docked web inspector pushing the page frame past the container
    /// bounds) and therefore needs normalizing.
    ///
    /// - Parameters:
    ///   - bounds: the reference rect to test containment against.
    ///   - epsilon: a tolerance so a sub-pixel overhang does not count as
    ///     extending outside. Defaults to `0.5`.
    public func extendsOutside(_ bounds: NSRect, epsilon: CGFloat = 0.5) -> Bool {
        minX < bounds.minX - epsilon ||
            minY < bounds.minY - epsilon ||
            maxX > bounds.maxX + epsilon ||
            maxY > bounds.maxY + epsilon
    }
}
