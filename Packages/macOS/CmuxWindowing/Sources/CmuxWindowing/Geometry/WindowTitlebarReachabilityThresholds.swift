public import CoreGraphics

/// Thresholds for deciding how much of a window's top strip must remain visible.
public struct WindowTitlebarReachabilityThresholds: Sendable {
    /// Height of the top-of-window strip that is inspected.
    public let topStripHeight: CGFloat
    /// Minimum visible width of that strip, capped to the window width.
    public let minimumVisibleWidth: CGFloat
    /// Minimum visible height of that strip, capped to the strip height.
    public let minimumVisibleHeight: CGFloat

    /// Creates titlebar-reachability thresholds.
    ///
    /// - Parameters:
    ///   - topStripHeight: Height of the top-of-window strip to inspect.
    ///   - minimumVisibleWidth: Minimum visible width required.
    ///   - minimumVisibleHeight: Minimum visible height required.
    public init(
        topStripHeight: CGFloat,
        minimumVisibleWidth: CGFloat,
        minimumVisibleHeight: CGFloat
    ) {
        self.topStripHeight = topStripHeight
        self.minimumVisibleWidth = minimumVisibleWidth
        self.minimumVisibleHeight = minimumVisibleHeight
    }

    /// The constrain-pass veto's generous anti-creep thresholds.
    public static let constrainVeto = WindowTitlebarReachabilityThresholds(
        topStripHeight: 64,
        minimumVisibleWidth: 60,
        minimumVisibleHeight: 24
    )
}
