public import CoreGraphics

/// A snapshot of one display's geometry used by session restore to choose a
/// target screen and clamp a restored window frame onto it.
///
/// A pure `Sendable` value type; the app target builds it from live `NSScreen`
/// state and session-restore math reads only these fields.
public struct SessionDisplayGeometry: Sendable {
    /// CoreGraphics display id, when resolvable.
    public let displayID: UInt32?
    /// The display's full frame in global screen coordinates.
    public let frame: CGRect
    /// The display's visible frame (excluding menu bar / Dock).
    public let visibleFrame: CGRect

    /// Creates a display-geometry snapshot.
    public init(
        displayID: UInt32?,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}
