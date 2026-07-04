public import CoreGraphics

/// One display's stable contribution to the main-window visible-frame fit gate.
///
/// Side and bottom `visibleFrame` insets are deliberately omitted so Dock
/// resizes do not look like display-topology changes. Full display frames,
/// display IDs, and top insets catch monitor arrangement and menu-bar changes.
public struct MainWindowVisibleFrameTopologySignatureEntry: Equatable, Sendable {
    /// CoreGraphics display id, when available.
    public let displayID: UInt32?
    /// The display's full frame in global screen coordinates.
    public let frame: CGRect
    /// Height excluded from the display's top edge.
    public let topInset: CGFloat

    /// Creates a topology-signature entry for one display.
    ///
    /// - Parameters:
    ///   - displayID: CoreGraphics display id, when available.
    ///   - frame: The display's full frame.
    ///   - visibleFrame: The display's visible frame after system insets.
    public init(
        displayID: UInt32?,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.displayID = displayID
        self.frame = frame
        self.topInset = frame.maxY - visibleFrame.maxY
    }
}
