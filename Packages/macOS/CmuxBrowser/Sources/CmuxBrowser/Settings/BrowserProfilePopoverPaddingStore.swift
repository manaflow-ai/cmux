public import Foundation

/// Reads and clamps the debug-tunable horizontal and vertical padding, in
/// points, around the browser profile popover content.
///
/// Each axis is persisted in `UserDefaults` under its own key
/// (``horizontalPaddingKey`` / ``verticalPaddingKey``) and constrained to its
/// allowed range (``horizontalPaddingRange`` / ``verticalPaddingRange``); a
/// value outside the range resolves to the matching default. Construct the store
/// with the `UserDefaults` to read from, then call ``currentHorizontalPadding()``
/// or ``currentVerticalPadding()``. The `resolved…` helpers expose the same
/// clamping for a raw value already held elsewhere (for example a SwiftUI
/// `@AppStorage` binding).
public struct BrowserProfilePopoverPaddingStore {
    /// `UserDefaults` key under which the horizontal padding is persisted.
    public static let horizontalPaddingKey = "browserProfilePopoverHorizontalPadding"

    /// `UserDefaults` key under which the vertical padding is persisted.
    public static let verticalPaddingKey = "browserProfilePopoverVerticalPadding"

    /// Horizontal padding used when no valid value is stored.
    public static let defaultHorizontalPadding = 12.0

    /// Vertical padding used when no valid value is stored.
    public static let defaultVerticalPadding = 10.0

    /// Allowed range, in points, for the horizontal padding.
    public static let horizontalPaddingRange = 8.0...20.0

    /// Allowed range, in points, for the vertical padding.
    public static let verticalPaddingRange = 4.0...14.0

    private let defaults: UserDefaults

    /// Creates a store reading from the given defaults.
    ///
    /// - Parameter defaults: The defaults to read the paddings from.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clamps a raw horizontal padding to its allowed range.
    ///
    /// - Parameter rawValue: The candidate horizontal padding in points.
    /// - Returns: `rawValue` when it lies in ``horizontalPaddingRange``,
    ///   otherwise ``defaultHorizontalPadding``.
    public static func resolvedHorizontalPadding(_ rawValue: Double) -> Double {
        horizontalPaddingRange.contains(rawValue) ? rawValue : defaultHorizontalPadding
    }

    /// Clamps a raw vertical padding to its allowed range.
    ///
    /// - Parameter rawValue: The candidate vertical padding in points.
    /// - Returns: `rawValue` when it lies in ``verticalPaddingRange``, otherwise
    ///   ``defaultVerticalPadding``.
    public static func resolvedVerticalPadding(_ rawValue: Double) -> Double {
        verticalPaddingRange.contains(rawValue) ? rawValue : defaultVerticalPadding
    }

    /// The currently stored horizontal padding, clamped to its range.
    ///
    /// - Returns: The resolved horizontal padding, or ``defaultHorizontalPadding``
    ///   when nothing valid is stored.
    public func currentHorizontalPadding() -> Double {
        Self.resolvedHorizontalPadding((defaults.object(forKey: Self.horizontalPaddingKey) as? NSNumber)?.doubleValue ?? Self.defaultHorizontalPadding)
    }

    /// The currently stored vertical padding, clamped to its range.
    ///
    /// - Returns: The resolved vertical padding, or ``defaultVerticalPadding``
    ///   when nothing valid is stored.
    public func currentVerticalPadding() -> Double {
        Self.resolvedVerticalPadding((defaults.object(forKey: Self.verticalPaddingKey) as? NSNumber)?.doubleValue ?? Self.defaultVerticalPadding)
    }
}
