public import Foundation

/// Reads the debug-only browser toolbar accessory spacing from `UserDefaults`.
///
/// This replaces the app target's caseless `BrowserToolbarAccessorySpacingDebugSettings`
/// namespace enum (all-`static` `UserDefaults` accessors) with a value type that takes
/// its `UserDefaults` through the initializer, mirroring ``BrowserImportHintRepository``.
/// The `static let` key/default/supported-values stay byte-identical to the app target
/// so the persisted value and the running browser agree, and the app's `@AppStorage(key)`
/// keeps resolving the same key.
public struct BrowserToolbarAccessorySpacingDebugRepository {
    /// The `UserDefaults` key storing the toolbar accessory spacing in points.
    public static let key = "browserToolbarAccessorySpacing"

    /// The shipped default spacing in points when no value is stored or the stored
    /// value is unsupported.
    public static let defaultSpacing = 2

    /// The spacing values the debug control offers.
    public static let supportedValues = [0, 2, 4, 6, 8]

    private let defaults: UserDefaults

    /// Creates a repository backed by the given `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clamps a raw spacing to a supported value, falling back to ``defaultSpacing``
    /// when the raw value is not one of ``supportedValues``.
    public func resolved(_ rawValue: Int) -> Int {
        Self.supportedValues.contains(rawValue) ? rawValue : Self.defaultSpacing
    }

    /// The currently stored spacing, resolved against ``supportedValues``.
    public func current() -> Int {
        resolved(defaults.object(forKey: Self.key) as? Int ?? Self.defaultSpacing)
    }
}
