public import Foundation

/// Reads the debug-only browser dev-tools button icon and color from `UserDefaults`.
///
/// This replaces the app target's caseless `BrowserDevToolsButtonDebugSettings`
/// namespace enum (all-`static` `UserDefaults` accessors) with a value type that takes
/// its `UserDefaults` through the initializer, mirroring ``BrowserToolbarAccessorySpacingDebugRepository``.
/// The `static let` keys/defaults stay byte-identical to the app target so the persisted
/// values and the running browser agree, the app's `@AppStorage(key)` keeps resolving the
/// same keys, and ``BrowserConfigTests`` keeps reading the same key/default symbols.
public struct BrowserDevToolsButtonDebugRepository {
    /// The `UserDefaults` key storing the dev-tools button SF Symbol name.
    public static let iconNameKey = "browserDevToolsIconName"

    /// The `UserDefaults` key storing the dev-tools button color option raw value.
    public static let iconColorKey = "browserDevToolsIconColor"

    /// The shipped default icon when no value is stored or the stored value is unknown.
    public static let defaultIcon = BrowserDevToolsIconOption.wrenchAndScrewdriver

    /// The shipped default color when no value is stored or the stored value is unknown.
    public static let defaultColor = BrowserDevToolsIconColorOption.bonsplitInactive

    private let defaults: UserDefaults

    /// Creates a repository backed by the given `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The currently stored icon, falling back to ``defaultIcon`` when the persisted
    /// raw value is missing or is not a known ``BrowserDevToolsIconOption``.
    public func iconOption() -> BrowserDevToolsIconOption {
        guard let raw = defaults.string(forKey: Self.iconNameKey),
              let option = BrowserDevToolsIconOption(rawValue: raw) else {
            return Self.defaultIcon
        }
        return option
    }

    /// The currently stored color, falling back to ``defaultColor`` when the persisted
    /// raw value is missing or is not a known ``BrowserDevToolsIconColorOption``.
    public func colorOption() -> BrowserDevToolsIconColorOption {
        guard let raw = defaults.string(forKey: Self.iconColorKey),
              let option = BrowserDevToolsIconColorOption(rawValue: raw) else {
            return Self.defaultColor
        }
        return option
    }

    /// A copyable, newline-separated dump of the persisted icon and color raw values,
    /// byte-identical to the app target's debug copy payload.
    public func copyPayload() -> String {
        let icon = iconOption()
        let color = colorOption()
        return """
        browserDevToolsIconName=\(icon.rawValue)
        browserDevToolsIconColor=\(color.rawValue)
        """
    }
}
