public import CoreGraphics

/// One display's stable contribution to the main-window visible-frame fit gate.
///
/// Side and bottom `visibleFrame` insets are deliberately omitted so Dock
/// resizes do not look like display-topology changes. Stable display identity,
/// full display frames, and top insets catch monitor arrangement and menu-bar
/// changes without treating raw display-ID churn as a topology change.
public struct MainWindowVisibleFrameTopologySignatureEntry: Equatable, Sendable {
    /// Stable physical display identity, when available.
    public let stableID: String?
    /// The display's full frame in global screen coordinates.
    public let frame: CGRect
    /// Height excluded from the display's top edge.
    public let topInset: CGFloat

    /// Creates a topology-signature entry for one display.
    ///
    /// - Parameters:
    ///   - stableID: Stable physical display identity, when available.
    ///   - frame: The display's full frame.
    ///   - visibleFrame: The display's visible frame after system insets.
    public init(
        stableID: String?,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.stableID = stableID
        self.frame = frame
        self.topInset = frame.maxY - visibleFrame.maxY
    }
}
