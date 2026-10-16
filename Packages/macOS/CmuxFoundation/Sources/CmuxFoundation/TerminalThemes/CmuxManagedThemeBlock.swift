public import Foundation

/// The `# cmux themes start` / `# cmux themes end` block cmux owns inside its
/// Ghostty config file.
///
/// `cmux themes` and the Settings theme gallery both write the terminal theme
/// through this block (via ``CmuxManagedThemeConfigFile``), so the rest of the
/// user's config is never rewritten. The bundled Ghostty picker
/// (`ghostty +list-themes` in cmux's Ghostty fork) writes the same format.
///
/// ```swift
/// let block = CmuxManagedThemeBlock()
/// let value = block.encodedThemeValue(light: "Catppuccin Latte", dark: "Catppuccin Mocha")!
/// let updated = block.applying(rawThemeValue: value, to: existingContents)
/// ```
public struct CmuxManagedThemeBlock: Sendable {
    /// The first line of the managed block.
    public let startMarker = "# cmux themes start"
    /// The last line of the managed block.
    public let endMarker = "# cmux themes end"

    /// Creates the block transform. It holds no state.
    public init() {}

    /// Returns `contents` with every managed block removed.
    ///
    /// Accepts LF and CRLF line endings. The line break after the block
    /// stays, so a block between two user lines does not join them.
    public func removing(from contents: String) -> String {
        let pattern = #"(?ms)(?:\r?\n)?# cmux themes start\r?\n.*?\r?\n# cmux themes end(?=\r?\n|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return contents
        }
        let fullRange = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        return regex.stringByReplacingMatches(in: contents, options: [], range: fullRange, withTemplate: "")
    }

    /// Returns `contents` with the managed block replaced by one that sets
    /// `theme = rawThemeValue`, placed after the user's own lines so it wins.
    ///
    /// The block uses CRLF when `contents` already does, so a CRLF file does
    /// not end up with mixed line endings.
    ///
    /// - Parameters:
    ///   - rawThemeValue: The value written after `theme = `.
    ///   - contents: The config file's current contents; empty for a new file.
    /// - Returns: The full new file contents, ending with a line break.
    public func applying(rawThemeValue: String, to contents: String) -> String {
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        let stripped = removing(from: contents).trimmingCharacters(in: .whitespacesAndNewlines)
        let block = [startMarker, "theme = \(rawThemeValue)", endMarker].joined(separator: newline)
        return stripped.isEmpty
            ? block + newline
            : stripped + newline + newline + block + newline
    }

    /// Returns `contents` without the managed block, or `nil` when nothing
    /// else remains and the file can be removed.
    public func clearing(_ contents: String) -> String? {
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        let stripped = removing(from: contents).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped + newline
    }

    /// The raw `theme` value inside the last managed block, or `nil` when
    /// `contents` has no managed block or the block sets no theme.
    public func themeValue(in contents: String) -> String? {
        var insideBlock = false
        var value: String?
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == startMarker {
                insideBlock = true
                value = nil
            } else if trimmed == endMarker {
                insideBlock = false
            } else if insideBlock, let equals = trimmed.firstIndex(of: "="),
                      trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "theme" {
                let raw = trimmed[trimmed.index(after: equals)...]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                value = raw.isEmpty ? nil : raw
            }
        }
        return value
    }

    /// Encodes a light and dark theme as Ghostty's conditional
    /// `light:<name>,dark:<name>` value.
    ///
    /// Ghostty rejects a conditional value that names only one side
    /// (manaflow-ai/cmux#10068), so a missing side mirrors the named one.
    ///
    /// - Returns: The encoded value, or `nil` when neither side names a theme.
    public func encodedThemeValue(light: String?, dark: String?) -> String? {
        let light = light?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let dark = dark?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let resolvedLight = light ?? dark, let resolvedDark = dark ?? light else {
            return nil
        }
        return "light:\(resolvedLight),dark:\(resolvedDark)"
    }

    /// Splits a raw `theme` directive value into the theme used in light and
    /// dark appearance.
    ///
    /// A plain name, or an unprefixed entry, applies to whichever side the
    /// value leaves unnamed. `nil` or blank input yields an empty pair.
    public func themePair(fromRawValue rawValue: String?) -> CmuxTerminalThemePair {
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

/// The Ghostty theme cmux uses in light and in dark appearance.
///
/// A `nil` side inherits Ghostty's default colors.
public struct CmuxTerminalThemePair: Equatable, Sendable {
    /// The theme name used in light appearance.
    public var light: String?
    /// The theme name used in dark appearance.
    public var dark: String?

    /// Creates a pair.
    /// - Parameters:
    ///   - light: The light-appearance theme, or `nil` for Ghostty's default.
    ///   - dark: The dark-appearance theme, or `nil` for Ghostty's default.
    public init(light: String?, dark: String?) {
        self.light = light
        self.dark = dark
    }
}
