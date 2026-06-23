public import Foundation

/// Reads the debug-only browser profile-popover padding from `UserDefaults`.
///
/// This replaces the app target's caseless `BrowserProfilePopoverDebugSettings`
/// namespace enum (all-`static` `UserDefaults` accessors) with a value type that takes
/// its `UserDefaults` through the initializer, mirroring ``BrowserImportHintRepository``.
/// The `static let` keys/defaults/ranges stay byte-identical to the app target so the
/// persisted values and the running browser agree, and the app's `@AppStorage(key)`
/// keeps resolving the same keys.
public struct BrowserProfilePopoverDebugRepository {
    /// The `UserDefaults` key storing the popover horizontal padding in points.
    public static let horizontalPaddingKey = "browserProfilePopoverHorizontalPadding"

    /// The `UserDefaults` key storing the popover vertical padding in points.
    public static let verticalPaddingKey = "browserProfilePopoverVerticalPadding"

    /// The shipped default horizontal padding in points.
    public static let defaultHorizontalPadding = 12.0

    /// The shipped default vertical padding in points.
    public static let defaultVerticalPadding = 10.0

    /// The accepted horizontal-padding range; values outside it fall back to the default.
    public static let horizontalPaddingRange = 8.0...20.0

    /// The accepted vertical-padding range; values outside it fall back to the default.
    public static let verticalPaddingRange = 4.0...14.0

    private let defaults: UserDefaults

    /// Creates a repository backed by the given `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clamps a raw horizontal padding to ``horizontalPaddingRange``, falling back to
    /// ``defaultHorizontalPadding`` when the raw value is out of range.
    public func resolvedHorizontalPadding(_ rawValue: Double) -> Double {
        Self.horizontalPaddingRange.contains(rawValue) ? rawValue : Self.defaultHorizontalPadding
    }

    /// Clamps a raw vertical padding to ``verticalPaddingRange``, falling back to
    /// ``defaultVerticalPadding`` when the raw value is out of range.
    public func resolvedVerticalPadding(_ rawValue: Double) -> Double {
        Self.verticalPaddingRange.contains(rawValue) ? rawValue : Self.defaultVerticalPadding
    }

    /// The currently stored horizontal padding, resolved against ``horizontalPaddingRange``.
    public func currentHorizontalPadding() -> Double {
        resolvedHorizontalPadding((defaults.object(forKey: Self.horizontalPaddingKey) as? NSNumber)?.doubleValue ?? Self.defaultHorizontalPadding)
    }

    /// The currently stored vertical padding, resolved against ``verticalPaddingRange``.
    public func currentVerticalPadding() -> Double {
        resolvedVerticalPadding((defaults.object(forKey: Self.verticalPaddingKey) as? NSNumber)?.doubleValue ?? Self.defaultVerticalPadding)
    }
}
