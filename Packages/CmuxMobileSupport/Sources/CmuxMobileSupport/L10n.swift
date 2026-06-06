public import Foundation

/// Localized-string helpers shared across the mobile packages.
///
/// Strings live in the app target's `Localizable.xcstrings`, so lookups default
/// to `Bundle.main`; this resolves correctly from any module at runtime. The
/// `bundle`-taking overloads let tests point lookups at a fixture bundle.
public struct L10n {
    private init() {}

    /// Resolve a localized string by key from an explicit bundle.
    ///
    /// - Parameters:
    ///   - key: The localization key present in the bundle's string catalog.
    ///   - defaultValue: The English source value used when the key is missing.
    ///   - bundle: The bundle whose string catalog to read.
    /// - Returns: The localized string from `bundle`.
    public static func string(_ key: StaticString, defaultValue: String.LocalizationValue, bundle: Bundle) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: bundle)
    }

    /// Resolve a localized string by key, falling back to a default value.
    ///
    /// - Parameters:
    ///   - key: The localization key present in the app's string catalog.
    ///   - defaultValue: The English source value used when the key is missing.
    /// - Returns: The localized string from `Bundle.main`.
    public static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        string(key, defaultValue: defaultValue, bundle: .main)
    }

    /// A localized "N terminals" count label with singular/plural handling.
    ///
    /// - Parameter count: The number of terminals.
    /// - Returns: The localized count phrase.
    public static func terminalCount(_ count: Int) -> String {
        if count == 1 {
            return string("mobile.workspace.terminalCountFormat.one", defaultValue: "1 terminal")
        }
        return String(format: string("mobile.workspace.terminalCountFormat.other", defaultValue: "%d terminals"), count)
    }

    /// A localized default workspace name for a given 1-based index.
    ///
    /// - Parameter index: The 1-based workspace index.
    /// - Returns: The localized workspace name (e.g. "Workspace 2").
    public static func workspaceName(index: Int) -> String {
        String(format: string("mobile.preview.workspaceNameFormat", defaultValue: "Workspace %d"), index)
    }

    /// A localized default terminal name for a given 1-based index.
    ///
    /// - Parameter index: The 1-based terminal index.
    /// - Returns: The localized terminal name (e.g. "Terminal 2").
    public static func terminalName(index: Int) -> String {
        String(format: string("mobile.preview.terminalNameFormat", defaultValue: "Terminal %d"), index)
    }
}
