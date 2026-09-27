public import CoreGraphics

/// The one pane size a terminal may publish to its renderer grid and PTY.
///
/// A host produces this value only from geometry the user can see: a pane
/// that layout has finished placing, or a pane that is being dragged and
/// whose every intermediate frame is therefore on screen. A hidden, detached,
/// or not-yet-laid-out frame never becomes a `TerminalPaneGeometry`, so it
/// cannot reach the PTY. The surface stores the last committed value and
/// re-applies it on demand instead of reading view bounds.
public struct TerminalPaneGeometry: Equatable, Sendable {
    /// The pane size in points.
    public var size: CGSize
    /// The window backing scale the pixel grid derives from.
    public var backingScale: CGFloat
    /// Whether the size comes from a drag tick or from settled layout.
    public var phase: Phase

    /// Creates a committed pane geometry.
    ///
    /// - Parameters:
    ///   - size: The pane size in points; both dimensions must be positive.
    ///   - backingScale: The window backing scale, clamped to at least 1.
    ///   - phase: Whether the size comes from a drag tick or settled layout.
    /// - Returns: `nil` when either dimension is not positive.
    public init?(size: CGSize, backingScale: CGFloat, phase: Phase) {
        guard size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else { return nil }
        self.size = size
        self.backingScale = max(1, backingScale)
        self.phase = phase
    }

    /// The pane size in backing pixels.
    public var backingSize: CGSize {
        CGSize(width: size.width * backingScale, height: size.height * backingScale)
    }
}
