public import CoreGraphics

/// A snapshot of one display's geometry used by session restore to choose a
/// target screen and clamp a restored window frame onto it.
///
/// A pure `Sendable` value type; the app target builds it from live `NSScreen`
/// state and session-restore math reads only these fields.
public struct SessionDisplayGeometry: Sendable {
    /// CoreGraphics display id, when resolvable.
    public let displayID: UInt32?
    /// A stable per-physical-display identity that survives reboot, GPU-mux, and
    /// port/reconnect — unlike ``displayID`` (a `CGDirectDisplayID`, which macOS
    /// reassigns). The app target builds it from
    /// `CGDisplayCreateUUIDFromDisplayID` with an EDID-triple fallback; `nil` when
    /// neither is resolvable (e.g. some virtual/AirPlay displays), in which case
    /// the display is excluded from any persisted configuration key. Used only
    /// for per-monitor geometry memory, never for restore-time clamping.
    public let stableID: String?
    /// The display's full frame in global screen coordinates.
    public let frame: CGRect
    /// The display's visible frame (excluding menu bar / Dock).
    public let visibleFrame: CGRect

    /// Creates a display-geometry snapshot.
    public init(
        displayID: UInt32?,
        stableID: String? = nil,
        frame: CGRect,
        visibleFrame: CGRect
    ) {
        self.displayID = displayID
        self.stableID = stableID
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}
