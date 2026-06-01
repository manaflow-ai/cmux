import Foundation

/// Per-extension destination used when Cmd-click opens a file path.
public enum FileExtensionOpenBehavior: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    /// Defer to the legacy Markdown and supported-file routing settings.
    case automatic
    /// Open the file in cmux's generic file preview surface.
    case cmuxPreview
    /// Open the file in cmux's rendered Markdown viewer.
    case markdownViewer
    /// Open the file URL in a cmux browser surface.
    case cmuxBrowser
    /// Open the file with the configured preferred editor command.
    case preferredEditor
    /// Hand the file to the operating system's default opener.
    case systemDefault

    /// Stable identifier matching the raw config value.
    public var id: String { rawValue }

    /// Built-in extension opener defaults applied before user overrides.
    public static let defaultOpeners: [String: FileExtensionOpenBehavior] = [
        "htm": .cmuxBrowser,
        "html": .cmuxBrowser,
    ]

    /// Normalizes a user-entered extension key for storage and lookup.
    ///
    /// Leading dots are stripped, case is folded, and only simple extension
    /// characters are accepted. Returns `nil` for empty or unsupported values.
    public static func normalizedExtension(_ rawValue: String) -> String? {
        var trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ character in
                  character.isLetter || character.isNumber || character == "-" || character == "_" || character == "+"
              }) else {
            return nil
        }
        return trimmed
    }

    /// Decodes stored opener behavior, treating unknown stored values as
    /// ``automatic`` so one corrupt UserDefaults entry does not hide the rest
    /// of the extension map in Settings.
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        guard let rawValue = String.decodeFromUserDefaults(raw) else { return nil }
        return Self(rawValue: rawValue) ?? .automatic
    }
}
