/// The display a saved window frame was captured on, inside a session snapshot.
///
/// A pure leaf value carrying the CoreGraphics `displayID` and the display's
/// `frame`/`visibleFrame` as `SessionRectSnapshot`s. Every field is optional
/// because a persisted snapshot may predate display metadata or omit it. The
/// on-disk wire format is owned by the app's `SessionWindowSnapshot`; encoding
/// stays byte-identical to the legacy app-target definition (default `Codable`
/// synthesis over the same stored-property set).
public struct SessionDisplaySnapshot: Codable, Sendable {
    /// CoreGraphics display id the frame was saved on, when recorded.
    public var displayID: UInt32?
    /// The source display's full frame, when recorded.
    public var frame: SessionRectSnapshot?
    /// The source display's visible frame (excluding menu bar / Dock), when
    /// recorded.
    public var visibleFrame: SessionRectSnapshot?

    /// Creates a persisted display snapshot.
    public init(
        displayID: UInt32? = nil,
        frame: SessionRectSnapshot? = nil,
        visibleFrame: SessionRectSnapshot? = nil
    ) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}
