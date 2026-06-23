public import Foundation

/// Reads and writes the persisted import-data hint configuration.
///
/// This replaces the app target's caseless `BrowserImportHintSettings` namespace
/// enum (all-`static` `UserDefaults` accessors) with a value type that takes its
/// `UserDefaults` through the initializer, mirroring the other `CmuxBrowser`
/// `Import` repositories. The `static let` keys/defaults stay byte-identical to
/// the app target so the stored state and the running browser agree.
public struct BrowserImportHintRepository {
    /// The `UserDefaults` key storing the selected ``BrowserImportHintVariant`` raw value.
    public static let variantKey = "browserImportHintVariant"

    /// The `UserDefaults` key for the "show on blank tabs" flag.
    public static let showOnBlankTabsKey = "browserImportHintShowOnBlankTabs"

    /// The `UserDefaults` key for the "dismissed" flag.
    public static let dismissedKey = "browserImportHintDismissed"

    /// The shipped default variant when no value is stored.
    public static let defaultVariant: BrowserImportHintVariant = .toolbarChip

    /// The shipped default for the "show on blank tabs" flag.
    public static let defaultShowOnBlankTabs = true

    /// The shipped default for the "dismissed" flag.
    public static let defaultDismissed = false

    private let defaults: UserDefaults

    /// Creates a repository backed by the given `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Resolves a stored raw value into a variant, falling back to
    /// ``defaultVariant`` when the value is missing or unrecognized.
    public func variant(for rawValue: String?) -> BrowserImportHintVariant {
        guard let rawValue, let variant = BrowserImportHintVariant(rawValue: rawValue) else {
            return Self.defaultVariant
        }
        return variant
    }

    /// The currently stored variant.
    public func variant() -> BrowserImportHintVariant {
        variant(for: defaults.string(forKey: Self.variantKey))
    }

    /// Whether the hint should show on blank tabs.
    public func showOnBlankTabs() -> Bool {
        if defaults.object(forKey: Self.showOnBlankTabsKey) == nil {
            return Self.defaultShowOnBlankTabs
        }
        return defaults.bool(forKey: Self.showOnBlankTabsKey)
    }

    /// Whether the hint has been dismissed.
    public func isDismissed() -> Bool {
        if defaults.object(forKey: Self.dismissedKey) == nil {
            return Self.defaultDismissed
        }
        return defaults.bool(forKey: Self.dismissedKey)
    }

    /// The derived presentation for the currently stored configuration.
    public func presentation() -> BrowserImportHintPresentation {
        BrowserImportHintPresentation(
            variant: variant(),
            showOnBlankTabs: showOnBlankTabs(),
            isDismissed: isDismissed()
        )
    }

    /// Resets every stored hint key back to its shipped default.
    public func reset() {
        defaults.set(Self.defaultVariant.rawValue, forKey: Self.variantKey)
        defaults.set(Self.defaultShowOnBlankTabs, forKey: Self.showOnBlankTabsKey)
        defaults.set(Self.defaultDismissed, forKey: Self.dismissedKey)
    }
}
