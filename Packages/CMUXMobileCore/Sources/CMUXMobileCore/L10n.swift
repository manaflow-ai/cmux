import Foundation

/// Localized-string helpers shared across the mobile packages.
///
/// Strings live in the app target's `Localizable.xcstrings`, so lookups use
/// `Bundle.main`; this resolves correctly from any module at runtime.
public enum L10n {
    public static func string(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .main)
    }

    public static func terminalCount(_ count: Int) -> String {
        if count == 1 {
            return string("mobile.workspace.terminalCountFormat.one", defaultValue: "1 terminal")
        }
        return String(format: string("mobile.workspace.terminalCountFormat.other", defaultValue: "%d terminals"), count)
    }

    public static func workspaceName(index: Int) -> String {
        String(format: string("mobile.preview.workspaceNameFormat", defaultValue: "Workspace %d"), index)
    }

    public static func terminalName(index: Int) -> String {
        String(format: string("mobile.preview.terminalNameFormat", defaultValue: "Terminal %d"), index)
    }
}
