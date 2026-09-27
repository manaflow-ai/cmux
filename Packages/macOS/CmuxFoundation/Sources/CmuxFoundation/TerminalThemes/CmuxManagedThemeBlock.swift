public import Foundation

/// The `# cmux themes start` / `# cmux themes end` block cmux owns inside its
/// Ghostty config file.
///
/// `cmux themes` and the Settings theme gallery both write the terminal theme
/// through this block, so the rest of the user's config is never rewritten.
/// The bundled Ghostty picker (`ghostty +list-themes` in cmux's Ghostty fork)
/// writes the same block format.
public enum CmuxManagedThemeBlock {
    /// The first line of the managed block.
    public static let startMarker = "# cmux themes start"
    /// The last line of the managed block.
    public static let endMarker = "# cmux themes end"

    /// Returns `contents` with every managed block removed. The newline after
    /// the block stays, so a block between two user lines does not join them.
    public static func removing(from contents: String) -> String {
        let pattern = #"(?ms)\n?# cmux themes start\n.*?\n# cmux themes end(?=\n|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
    }

    /// Returns `contents` with the managed block replaced by one that sets
    /// `theme = rawThemeValue`, placed after the user's own lines so it wins.
    public static func applying(rawThemeValue: String, to contents: String) -> String {
        let stripped = removing(from: contents).trimmingCharacters(in: .whitespacesAndNewlines)
        let block = "\(startMarker)\ntheme = \(rawThemeValue)\n\(endMarker)"
        return stripped.isEmpty ? "\(block)\n" : "\(stripped)\n\n\(block)\n"
    }

    /// Returns `contents` without the managed block, or `nil` when nothing
    /// else remains and the file can be removed.
    public static func clearing(_ contents: String) -> String? {
        let stripped = removing(from: contents).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : "\(stripped)\n"
    }

    /// Encodes a light and dark theme as Ghostty's conditional
    /// `light:<name>,dark:<name>` value.
    ///
    /// Ghostty rejects a conditional value that names only one side
    /// (manaflow-ai/cmux#10068), so a missing side mirrors the named one.
    /// Returns `nil` when neither side names a theme.
    public static func encodedThemeValue(light: String?, dark: String?) -> String? {
        let light = light?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let dark = dark?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let resolvedLight = light ?? dark, let resolvedDark = dark ?? light else {
            return nil
        }
        return "light:\(resolvedLight),dark:\(resolvedDark)"
    }

    /// Splits a raw `theme` directive value into the theme used in light and
    /// dark appearance. A plain name, or an unprefixed entry, applies to
    /// whichever side the value leaves unnamed.
    public static func themePair(fromRawValue rawValue: String?) -> CmuxTerminalThemePair {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return CmuxTerminalThemePair(light: nil, dark: nil)
        }

        var fallback: String?
        var light: String?
        var dark: String?
        for token in rawValue.split(separator: ",") {
            let entry = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !entry.isEmpty else { continue }
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                if fallback == nil { fallback = entry }
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            switch key {
            case "light":
                if light == nil { light = value }
            case "dark":
                if dark == nil { dark = value }
            default:
                if fallback == nil { fallback = value }
            }
        }
        return CmuxTerminalThemePair(light: light ?? fallback, dark: dark ?? fallback)
    }
}

/// The Ghostty theme cmux uses in light and in dark appearance. `nil` means
/// the side inherits Ghostty's default colors.
public struct CmuxTerminalThemePair: Equatable, Sendable {
    public var light: String?
    public var dark: String?

    public init(light: String?, dark: String?) {
        self.light = light
        self.dark = dark
    }
}
