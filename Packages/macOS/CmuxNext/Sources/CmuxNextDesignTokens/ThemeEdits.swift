package import Foundation

/// Per-token color edits to Ghostty themes (`appearance.themeEdits` in cmux.json, cx-wqn5): a
/// derived custom theme ("Rose Pine (custom)") that never changes the theme's own file. The theme
/// loads, then its edits, so an edited token wins and the others stay the theme's. Keyed by theme
/// name, so the edits follow the theme wherever it applies (the app, a space, a workspace, a terminal).
public nonisolated struct ThemeEdits: Hashable, Sendable {
    /// The tokens an edit can set: the terminal's background, foreground, cursor and selection,
    /// the 16 ANSI palette colors ("0" to "15"), and the app accent for this theme ("accent", over
    /// `appearance.accent`; not a Ghostty color, so it has no config line).
    public static let tokens: [String] = ["background", "foreground", "cursor", "selection"] + (0..<16).map(String.init)
        + ["accent"]

    /// Theme name to token to `#rrggbb`.
    public private(set) var colors: [String: [String: String]]

    /// `appearance.highlightColor` (`#rrggbb`): the app's one highlight color, over every theme's
    /// selection, loaded after the theme and its edits (`GhosttyRuntime.highlightLines`). Nil keeps
    /// each theme's own.
    public var highlight: String? {
        didSet { if let highlight, !Self.isColor(highlight) { self.highlight = nil } }
    }

    public static let none = ThemeEdits()

    public init(_ colors: [String: [String: String]] = [:], highlight: String? = nil) {
        self.highlight = highlight.flatMap { Self.isColor($0) ? $0.lowercased() : nil }
        self.colors = colors.compactMapValues { tokens in
            let kept = tokens.filter { Self.tokens.contains($0.key) && Self.isColor($0.value) }.mapValues { $0.lowercased() }
            return kept.isEmpty ? nil : kept
        }
    }

    public var isEmpty: Bool { colors.isEmpty }

    /// Whether `theme` has edits: it shows as "<theme> (custom)".
    public func isEdited(_ theme: String) -> Bool { colors[theme] != nil }

    /// `#rrggbb` (no alpha: Ghostty's theme colors are opaque).
    public static func isColor(_ text: String) -> Bool {
        text.count == 7 && text.first == "#" && text.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// `theme`'s accent edit, `#rrggbb`; nil without one.
    public func accent(for theme: String) -> String? { colors[theme]?["accent"] }

    /// The Ghostty config lines for `theme`'s edits, loaded after its `theme =` line, in a stable
    /// order (named tokens, then the palette by index).
    public func configLines(for theme: String) -> [String] {
        guard let edits = colors[theme] else { return [] }
        return Self.tokens.compactMap { token in
            guard let color = edits[token] else { return nil }
            switch token {
            case "background": return "background = \(color)"
            case "foreground": return "foreground = \(color)"
            case "cursor": return "cursor-color = \(color)"
            case "selection": return "selection-background = \(color)"
            case "accent": return nil
            default: return "palette = \(token)=\(color)"
            }
        }
    }
}
