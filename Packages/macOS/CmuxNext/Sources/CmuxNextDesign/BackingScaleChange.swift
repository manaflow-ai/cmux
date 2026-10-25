public import CoreGraphics

/// The backing scale a view last did its scale work for, so `viewDidChangeBackingProperties` acts
/// only on a real scale change.
///
/// AppKit calls `viewDidChangeBackingProperties` on a whole subtree for more than a move to a screen of
/// another scale: a canvas screen's camera sets its bounds size on every zoom frame
/// (`ScreenContentView.applyCamera`), and every view under it heard the callback each frame (Crash D,
/// issue #24998).
///
/// ```swift
/// private var backingScale = BackingScaleChange()
///
/// override func viewDidChangeBackingProperties() {
///     super.viewDidChangeBackingProperties()
///     guard backingScale.isChange(to: window?.backingScaleFactor) else { return }
///     density.reapply()
/// }
/// ```
public nonisolated struct BackingScaleChange: Sendable {
    private var last: CGFloat?

    /// No scale seen yet: the first call with a window's scale is a change.
    public init() {}

    /// Whether `scale` differs from the last scale this returned true for, and records it.
    ///
    /// - Parameter scale: The window's backing scale now; nil (no window) is never a change.
    /// - Returns: True on the first scale and on every later different one.
    public mutating func isChange(to scale: CGFloat?) -> Bool {
        guard let scale, scale != last else { return false }
        last = scale
        return true
    }
}
