public import CoreGraphics

/// The display a saved window frame was captured on, as the session
/// frame resolver reads it.
///
/// This is the resolver's runtime input, not a persisted DTO: every field is
/// optional because a persisted snapshot may predate display metadata or omit
/// it. The app maps its `Codable` on-disk display snapshot into this value at
/// the call seam, so the wire format stays owned by the app target while the
/// frame math stays in this package.
public struct SessionSourceDisplaySnapshot: Sendable {
    /// CoreGraphics display id the frame was saved on, when recorded.
    public let displayID: UInt32?
    /// The source display's full frame in global screen coordinates, when
    /// recorded.
    public let frame: CGRect?
    /// The source display's visible frame (excluding menu bar / Dock), when
    /// recorded.
    public let visibleFrame: CGRect?

    /// Creates a source-display snapshot for frame resolution.
    public init(
        displayID: UInt32?,
        frame: CGRect?,
        visibleFrame: CGRect?
    ) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}
