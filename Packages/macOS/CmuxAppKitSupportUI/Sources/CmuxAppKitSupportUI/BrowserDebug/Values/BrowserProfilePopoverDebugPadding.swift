#if canImport(AppKit)

public import Foundation

/// The resolved horizontal and vertical padding the browser profile popover debug
/// panel tunes live.
///
/// A value instance carries the two clamped padding amounts; the panel constructs
/// one from the stored raw `UserDefaults` values via ``init(rawHorizontal:rawVertical:)``,
/// which clamps each axis to its valid range. The `UserDefaults` keys, defaults,
/// and ranges are byte-identical to the app target's live profile-popover settings,
/// so the debug panel drives the same stored state the running profile popover
/// reads.
public struct BrowserProfilePopoverDebugPadding: Equatable, Sendable {
    /// The `UserDefaults` key for the horizontal padding.
    public static let horizontalPaddingKey = "browserProfilePopoverHorizontalPadding"

    /// The `UserDefaults` key for the vertical padding.
    public static let verticalPaddingKey = "browserProfilePopoverVerticalPadding"

    /// The shipped default horizontal padding.
    public static let defaultHorizontalPadding = 12.0

    /// The shipped default vertical padding.
    public static let defaultVerticalPadding = 10.0

    /// The valid horizontal padding range; values outside clamp to the default.
    public static let horizontalPaddingRange = 8.0...20.0

    /// The valid vertical padding range; values outside clamp to the default.
    public static let verticalPaddingRange = 4.0...14.0

    /// The clamped horizontal padding.
    public let horizontal: Double

    /// The clamped vertical padding.
    public let vertical: Double

    /// Creates a padding value from already-clamped amounts.
    public init(horizontal: Double, vertical: Double) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// Creates a padding value by clamping raw stored amounts to their valid
    /// ranges, falling back to the defaults when out of range.
    public init(rawHorizontal: Double, rawVertical: Double) {
        self.horizontal = Self.clampedHorizontal(rawHorizontal)
        self.vertical = Self.clampedVertical(rawVertical)
    }

    /// Clamps a raw horizontal padding to its valid range, falling back to the
    /// default when out of range.
    public static func clampedHorizontal(_ rawValue: Double) -> Double {
        horizontalPaddingRange.contains(rawValue) ? rawValue : defaultHorizontalPadding
    }

    /// Clamps a raw vertical padding to its valid range, falling back to the
    /// default when out of range.
    public static func clampedVertical(_ rawValue: Double) -> Double {
        verticalPaddingRange.contains(rawValue) ? rawValue : defaultVerticalPadding
    }
}

#endif
