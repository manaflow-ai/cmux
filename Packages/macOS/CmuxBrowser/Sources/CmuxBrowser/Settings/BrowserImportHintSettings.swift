public import Foundation

/// Reads, resolves, and resets the persisted "import your data from another
/// browser" hint preferences.
///
/// Three independent values are persisted in `UserDefaults`: the presentation
/// ``BrowserImportHintVariant`` (under ``variantKey``), whether the hint may
/// appear on blank tabs (under ``showOnBlankTabsKey``), and whether the user has
/// dismissed it (under ``dismissedKey``). Each missing value falls back to its
/// matching default. Construct the store with the `UserDefaults` to read from,
/// then call ``variant()``, ``showOnBlankTabs()``, ``isDismissed()``, or
/// ``presentation()``; ``reset()`` restores all three to their defaults. The
/// static ``variant(for:)`` exposes the same raw-value clamping for a value
/// already held elsewhere (for example a SwiftUI `@AppStorage` binding).
public struct BrowserImportHintSettings {
    /// `UserDefaults` key under which the hint variant raw value is persisted.
    public static let variantKey = "browserImportHintVariant"

    /// `UserDefaults` key under which the blank-tab visibility flag is persisted.
    public static let showOnBlankTabsKey = "browserImportHintShowOnBlankTabs"

    /// `UserDefaults` key under which the dismissal flag is persisted.
    public static let dismissedKey = "browserImportHintDismissed"

    /// The variant used when no valid value is stored.
    public static let defaultVariant: BrowserImportHintVariant = .toolbarChip

    /// The blank-tab visibility used when no value is stored.
    public static let defaultShowOnBlankTabs = true

    /// The dismissal state used when no value is stored.
    public static let defaultDismissed = false

    private let defaults: UserDefaults

    /// Creates a store reading from the given defaults.
    ///
    /// - Parameter defaults: The defaults to read the hint preferences from.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Clamps a raw variant string to a known variant.
    ///
    /// - Parameter rawValue: The candidate variant raw value, if any.
    /// - Returns: The matching ``BrowserImportHintVariant``, or
    ///   ``defaultVariant`` when `rawValue` is `nil` or unrecognized.
    public static func variant(for rawValue: String?) -> BrowserImportHintVariant {
        guard let rawValue, let variant = BrowserImportHintVariant(rawValue: rawValue) else {
            return defaultVariant
        }
        return variant
    }

    /// The currently stored variant, clamped to a known value.
    ///
    /// - Returns: The resolved variant, or ``defaultVariant`` when nothing valid
    ///   is stored.
    public func variant() -> BrowserImportHintVariant {
        Self.variant(for: defaults.string(forKey: Self.variantKey))
    }

    /// Whether the hint may appear on blank tabs.
    ///
    /// - Returns: The stored flag, or ``defaultShowOnBlankTabs`` when unset.
    public func showOnBlankTabs() -> Bool {
        if defaults.object(forKey: Self.showOnBlankTabsKey) == nil {
            return Self.defaultShowOnBlankTabs
        }
        return defaults.bool(forKey: Self.showOnBlankTabsKey)
    }

    /// Whether the user has dismissed the hint.
    ///
    /// - Returns: The stored flag, or ``defaultDismissed`` when unset.
    public func isDismissed() -> Bool {
        if defaults.object(forKey: Self.dismissedKey) == nil {
            return Self.defaultDismissed
        }
        return defaults.bool(forKey: Self.dismissedKey)
    }

    /// The resolved hint placement for the current stored preferences.
    ///
    /// - Returns: A ``BrowserImportHintPresentation`` built from ``variant()``,
    ///   ``showOnBlankTabs()``, and ``isDismissed()``.
    public func presentation() -> BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: variant(),
            showOnBlankTabs: showOnBlankTabs(),
            isDismissed: isDismissed()
        )
    }

    /// Restores all three hint preferences to their defaults.
    public func reset() {
        defaults.set(Self.defaultVariant.rawValue, forKey: Self.variantKey)
        defaults.set(Self.defaultShowOnBlankTabs, forKey: Self.showOnBlankTabsKey)
        defaults.set(Self.defaultDismissed, forKey: Self.dismissedKey)
    }
}
