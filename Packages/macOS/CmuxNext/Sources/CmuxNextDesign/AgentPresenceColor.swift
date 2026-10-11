public import AppKit
public import CmuxTheme

/// An agent's presence color (cx-gg84): one of the theme's ANSI accents,
/// picked by a stable hash of the agent's key (its session id), so the same
/// agent keeps its color across rows, panes and restarts, and the colors
/// follow the terminal palette. Kept readable over the sidebar like the group
/// colors (`GroupColor.themeRGB`).
public nonisolated enum AgentPresenceColor {
    /// The accents in pick order: the group colors' automatic order, then
    /// blue, which presence may use because it is never the app's selection.
    static let order: [GroupColor] = GroupColor.automaticOrder + [.blue]

    /// The color for `key` in `tokens`' palette.
    public static func rgb(forKey key: String, tokens: ThemeTokens) -> ThemeRGB {
        let color = order[index(forKey: key, count: order.count)]
        return color.themeRGB(tokens) ?? color.headerRGB(tokens)
    }

    /// The color for `key` in the active theme scope.
    @MainActor public static func color(forKey key: String) -> NSColor {
        rgb(forKey: key, tokens: ThemeContext.active ?? ThemeScope.app.tokens).nsColor
    }

    /// Text on the presence color for `key`: black or white, whichever reads
    /// better in the active theme.
    @MainActor public static func ink(forKey key: String) -> NSColor {
        GroupColor.ink(on: rgb(forKey: key, tokens: ThemeContext.active ?? ThemeScope.app.tokens)).nsColor
    }

    /// FNV-1a over the key's Unicode scalars, modulo `count`.
    static func index(forKey key: String, count: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for scalar in key.unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}
