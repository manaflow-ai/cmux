public import AppKit
public import CmuxTheme
public import CmuxNextDesignTokens

/// An agent's presence color (cx-gg84): one of the theme's ANSI accents,
/// picked by a stable hash of the agent's key (its session id), so the same
/// agent keeps its color across rows, panes and restarts, and the colors
/// follow the terminal palette, kept readable over the sidebar (`GroupColor.themeRGB`).
public nonisolated struct AgentPresenceColor: Sendable {
    /// The accents in pick order (``GroupColor/presenceOrder``).
    static let order: [GroupColor] = GroupColor.presenceOrder

    /// The agent's color key (its session id).
    public let key: String

    public init(key: String) { self.key = key }

    /// The color in `tokens`' palette.
    public func rgb(tokens: ThemeTokens) -> ThemeRGB {
        Self.rgb(of: Self.order[Self.index(forKey: key, count: Self.order.count)], tokens: tokens)
    }

    /// One of the accents in `tokens`' palette, kept readable over the sidebar.
    static func rgb(of color: GroupColor, tokens: ThemeTokens) -> ThemeRGB {
        color.themeRGB(tokens) ?? color.swatchRGB(tokens)
    }

    /// The color in the active theme scope.
    @MainActor public var color: NSColor {
        rgb(tokens: ThemeContext.active ?? ThemeScope.app.tokens).nsColor
    }

    /// Text on the color: black or white, whichever reads better in the
    /// active theme.
    @MainActor public var ink: NSColor {
        GroupColor.ink(on: rgb(tokens: ThemeContext.active ?? ThemeScope.app.tokens)).nsColor
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
