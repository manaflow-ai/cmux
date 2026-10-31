import AppKit

/// The Chief's status line's shimmer (red stub: not drawn yet).
@MainActor
final class HomeNoticeShimmer {
    /// The animation's key on ``band``.
    static let animationKey = "shimmer"
    /// The row bitmap's mask.
    let mask = CALayer()
    /// The light band that sweeps the line.
    let band = CAGradientLayer()
    /// Whether the band sweeps now.
    var isRunning: Bool { false }
}
