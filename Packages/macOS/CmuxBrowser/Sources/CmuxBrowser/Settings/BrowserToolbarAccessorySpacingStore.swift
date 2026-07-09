public import Foundation

/// Reads and clamps the debug-tunable spacing, in points, between accessory
/// controls in the browser toolbar.
///
/// The value is persisted in `UserDefaults` under ``key`` and is constrained to
/// the discrete set of ``supportedValues``; any other stored value resolves to
/// ``defaultSpacing``. Construct the store with the `UserDefaults` to read from,
/// then call ``current()``. ``resolved(_:)`` exposes the same clamping for a raw
/// value already held elsewhere (for example a SwiftUI `@AppStorage` binding).
public struct BrowserToolbarAccessorySpacingStore {
    /// `UserDefaults` key under which the spacing is persisted.
    public static let key = "browserToolbarAccessorySpacing"

    /// Spacing used when no valid value is stored.
    public static let defaultSpacing = 2

    /// The discrete spacings the debug control offers, in points.
    public static let supportedValues = [0, 2, 4, 6, 8]

    private let defaults: UserDefaults

    /// Creates a store reading from the given defaults.
    ///
    /// - Parameter defaults: The defaults to read the spacing from.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clamps a raw spacing to the nearest valid value.
    ///
    /// - Parameter rawValue: The candidate spacing in points.
    /// - Returns: `rawValue` when it is one of ``supportedValues``, otherwise
    ///   ``defaultSpacing``.
    public static func resolved(_ rawValue: Int) -> Int {
        supportedValues.contains(rawValue) ? rawValue : defaultSpacing
    }

    /// The currently stored spacing, clamped to a valid value.
    ///
    /// - Returns: The resolved spacing, or ``defaultSpacing`` when nothing valid
    ///   is stored.
    public func current() -> Int {
        Self.resolved(defaults.object(forKey: Self.key) as? Int ?? Self.defaultSpacing)
    }
}
