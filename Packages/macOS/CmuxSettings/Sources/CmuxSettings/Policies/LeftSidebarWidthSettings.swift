import Foundation

/// Policy values and normalization helpers for the left (workspace) sidebar's
/// minimum resize width.
///
/// The left sidebar can never be dragged narrower than this floor. It mirrors
/// ``RightSidebarWidthSettings`` so the catalog key, the `cmux.json` loader, the
/// Settings pane, and the window layout share one definition.
public struct LeftSidebarWidthSettings: Sendable {
    /// Creates a stateless left sidebar width policy value.
    public init() {}

    /// The `cmux.json` key under `sidebar` that stores the minimum width.
    public static let jsonKey = "leftMinWidth"

    /// The dotted settings path for the minimum width.
    public static let settingsPath = "sidebar.leftMinWidth"

    /// The `UserDefaults` key that stores the active minimum width.
    ///
    /// This is the historical `sidebarMinimumWidth` key, so values written with
    /// `defaults write` before this setting existed keep working.
    public static let minimumWidthKey = "sidebarMinimumWidth"

    /// The minimum width, in points, used when nothing is configured.
    public static let defaultMinimumWidth = 240.0

    /// The smallest configurable minimum width, in points.
    public static let lowerBound = 120.0

    /// The largest configurable minimum width, in points.
    public static let upperBound = 260.0

    /// The supported range for the configured minimum width.
    public static let range: ClosedRange<Double> = lowerBound...upperBound

    /// Clamps a requested minimum width to ``range``.
    ///
    /// - Parameter value: The requested minimum width in points.
    /// - Returns: A width within ``range``, or ``defaultMinimumWidth`` when the
    ///   value is not finite.
    public func clampedMinimumWidth(_ value: Double) -> Double {
        guard value.isFinite else {
            return Self.defaultMinimumWidth
        }
        return min(Self.upperBound, max(Self.lowerBound, value))
    }
}
