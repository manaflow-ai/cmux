public import Foundation

/// Reads and serializes the persisted debug preferences for the browser panel's
/// DevTools button.
///
/// Two values are persisted in `UserDefaults`: the SF Symbol
/// ``BrowserDevToolsIconOption`` (under ``iconNameKey``) and the tint
/// ``BrowserDevToolsIconColorOption`` (under ``iconColorKey``). Each missing or
/// unrecognized value falls back to its matching default. Construct the store
/// with the `UserDefaults` to read from, then call ``iconOption()``,
/// ``colorOption()``, or ``copyPayload()``.
public struct BrowserDevToolsButtonDebugSettings {
    /// `UserDefaults` key under which the DevTools icon symbol name is persisted.
    public static let iconNameKey = "browserDevToolsIconName"

    /// `UserDefaults` key under which the DevTools icon tint raw value is persisted.
    public static let iconColorKey = "browserDevToolsIconColor"

    /// The icon used when no valid value is stored.
    public static let defaultIcon = BrowserDevToolsIconOption.wrenchAndScrewdriver

    /// The tint used when no valid value is stored.
    public static let defaultColor = BrowserDevToolsIconColorOption.bonsplitInactive

    private let defaults: UserDefaults

    /// Creates a store reading from the given defaults.
    ///
    /// - Parameter defaults: The defaults to read the DevTools button
    ///   preferences from.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The currently stored icon, clamped to a known value.
    ///
    /// - Returns: The resolved icon, or ``defaultIcon`` when nothing valid is
    ///   stored.
    public func iconOption() -> BrowserDevToolsIconOption {
        guard let raw = defaults.string(forKey: Self.iconNameKey),
              let option = BrowserDevToolsIconOption(rawValue: raw) else {
            return Self.defaultIcon
        }
        return option
    }

    /// The currently stored tint, clamped to a known value.
    ///
    /// - Returns: The resolved tint, or ``defaultColor`` when nothing valid is
    ///   stored.
    public func colorOption() -> BrowserDevToolsIconColorOption {
        guard let raw = defaults.string(forKey: Self.iconColorKey),
              let option = BrowserDevToolsIconColorOption(rawValue: raw) else {
            return Self.defaultColor
        }
        return option
    }

    /// The DevTools button config serialized as `key=value` lines for the debug
    /// "Copy" actions.
    ///
    /// - Returns: A two-line payload carrying the stored icon and tint raw values.
    public func copyPayload() -> String {
        let icon = iconOption()
        let color = colorOption()
        return """
        browserDevToolsIconName=\(icon.rawValue)
        browserDevToolsIconColor=\(color.rawValue)
        """
    }
}
