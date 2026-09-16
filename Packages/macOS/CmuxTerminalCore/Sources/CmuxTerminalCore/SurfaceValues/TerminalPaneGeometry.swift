public import CoreGraphics

/// The one pane size a terminal may publish to its renderer grid and PTY.
public struct TerminalPaneGeometry: Equatable, Sendable {
    /// Why the host considers this size publishable.
    public enum Phase: Equatable, Sendable {
        /// A window-edge or divider drag is in progress.
        case interactive
        /// Layout has stopped changing.
        case settled
    }

    /// The pane size in points.
    public var size: CGSize
    /// The window backing scale used to derive pixels.
    public var backingScale: CGFloat
    /// Whether the size comes from a drag tick or settled layout.
    public var phase: Phase

    /// Creates a valid pane geometry value.
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
