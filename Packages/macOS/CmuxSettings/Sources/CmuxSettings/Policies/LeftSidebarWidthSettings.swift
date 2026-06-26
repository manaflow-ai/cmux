import Foundation

/// Policy values and normalization helpers for the left (workspace) sidebar's
/// minimum resize width.
///
/// The left sidebar can never be dragged narrower than this floor. The floor is
/// configurable so users can reclaim horizontal space for the terminal without
/// hiding the sidebar entirely. Mirrors ``RightSidebarWidthSettings`` so both
/// sidebar width policies live in one place.
public struct LeftSidebarWidthSettings: Sendable {
    /// Creates a stateless left sidebar width policy value.
    public init() {}

    /// The `cmux.json` key under `sidebar` that stores the left sidebar minimum width.
    public static let jsonKey = "leftMinWidth"

    /// The dotted settings path for the left sidebar minimum width.
    public static let settingsPath = "sidebar.leftMinWidth"

    /// The `UserDefaults` key that stores the active left sidebar minimum width.
    ///
    /// Kept as the historical `sidebarMinimumWidth` key so existing stored values
    /// (and the Titlebar Layout debug window) continue to resolve unchanged.
    public static let minimumWidthKey = "sidebarMinimumWidth"

    /// The default minimum width, in points, used when no override is active.
    ///
    /// Matches the historical hard-coded floor so a fresh sidebar is unchanged.
    public static let defaultMinimumWidth = 216.0

    /// The smallest configurable minimum width, in points.
    public static let lowerBound = 100.0

    /// The largest configurable minimum width, in points.
    public static let upperBound = 260.0

    /// The supported configurable range for the minimum width.
    public static let range: ClosedRange<Double> = lowerBound...upperBound

    /// Clamps a requested minimum width to the supported range.
    ///
    /// - Parameter value: The requested minimum width in points.
    /// - Returns: A finite minimum width within ``range``, or the default when the
    ///   value is not finite.
    public func clampedMinimumWidth(_ value: Double) -> Double {
        guard value.isFinite else {
            return Self.defaultMinimumWidth
        }
        return min(Self.upperBound, max(Self.lowerBound, value))
    }
}
