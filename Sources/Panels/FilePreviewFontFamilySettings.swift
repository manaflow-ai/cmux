import AppKit
import Foundation

/// Persistent font-family selection for the built-in plain-text file editor.
///
/// The stored value is an AppKit font family name. An empty value preserves the
/// editor's established monospaced system font.
enum FilePreviewFontFamilySettings {
    /// UserDefaults / cmux.json key (`fileEditor.fontFamily`).
    static let key = "fileEditor.fontFamily"

    /// Empty means the established monospaced system font.
    static let defaultFamily = ""

    /// Normalizes config and settings input before it reaches AppKit.
    /// Newlines are collapsed so malformed JSON cannot create a multiline name.
    static func normalized(_ family: String) -> String {
        family
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The configured family, or the built-in empty sentinel when unset.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> String {
        normalized(defaults.string(forKey: key) ?? defaultFamily)
    }

    /// Persists a normalized family for newly opened editors.
    static func setDefault(_ family: String, defaults: UserDefaults = .standard) {
        let normalizedFamily = normalized(family)
        if normalizedFamily.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(normalizedFamily, forKey: key)
        }
    }

    /// Resolves a family name at a scaled point size, returning `nil` when the
    /// requested family is unavailable so callers can preserve the monospaced
    /// system fallback.
    static func font(family: String, scaledPointSize: CGFloat) -> NSFont? {
        let normalizedFamily = normalized(family)
        guard !normalizedFamily.isEmpty, scaledPointSize.isFinite, scaledPointSize > 0 else {
            return nil
        }

        // NSFontManager resolves family names (including multi-word families),
        // while NSFont(name:) also accepts PostScript names used by some custom
        // fonts. Try both forms before falling back to the caller's baseline.
        return NSFontManager.shared.font(
            withFamily: normalizedFamily,
            traits: [],
            weight: 5,
            size: scaledPointSize
        ) ?? NSFont(name: normalizedFamily, size: scaledPointSize)
    }
}
