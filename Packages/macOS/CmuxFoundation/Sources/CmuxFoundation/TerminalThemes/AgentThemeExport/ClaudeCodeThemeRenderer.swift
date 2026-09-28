import Foundation

/// Renders a terminal palette as a Claude Code custom theme.
///
/// Claude Code reads `~/.claude/themes/<slug>.json` with a `name`, a built-in
/// `base` preset and color `overrides`; see "Create a custom theme" in the
/// Claude Code terminal configuration docs. A Claude Code theme has one set of
/// colors, so a light/dark pair is exported one appearance at a time.
///
/// Mapping, by ANSI index (0 black, 1 red, 2 green, 3 yellow, 4 blue,
/// 5 magenta, 6 cyan, 8-15 bright):
/// - `claude` (spinner, assistant label) is magenta. Most palettes make it
///   their signature accent (Dracula purple, Tokyo Night magenta, Catppuccin
///   pink), and it keeps yellow free for `warning`.
/// - Status colors come straight from red, green and yellow.
/// - Grays (`inactive`, `subtle`, `promptBorder`) are foreground-to-background
///   blends rather than ANSI 8, which some themes set too close to the
///   background to read.
/// - Mode accents take hues the status colors don't: plan mode cyan,
///   accept-edits green, `!` shell pink (bright magenta), dialogs blue.
/// - Diff and message backgrounds are the background with a little of the
///   matching color mixed in. Shimmer variants, the lighter color in the
///   spinner's animated gradient, mix 30% white into their base.
/// - Subagent colors use the matching ANSI color; orange is red and yellow mixed.
public struct ClaudeCodeThemeRenderer: Sendable {
    /// Creates the renderer. It holds no state.
    public init() {}

    /// Renders the theme file.
    /// - Parameters:
    ///   - name: The label `/theme` shows.
    ///   - palette: The terminal palette to match.
    /// - Returns: The theme file's JSON, ending in a newline.
    public func render(name: String, palette: TerminalPalette) -> String {
        let bg = palette.background
        let fg = palette.foreground
        let dark = palette.isDark
        func ansi(_ index: Int) -> GhosttyThemeRGB { palette.ansi[index] }
        func gray(_ foregroundShare: Double) -> GhosttyThemeRGB {
            bg.mixed(toward: fg, amount: foregroundShare)
        }
        func tint(_ color: GhosttyThemeRGB, _ amount: Double) -> GhosttyThemeRGB {
            bg.mixed(toward: color, amount: amount)
        }
        func shimmer(_ color: GhosttyThemeRGB) -> GhosttyThemeRGB {
            color.mixed(toward: GhosttyThemeRGB(red: 0xFF, green: 0xFF, blue: 0xFF), amount: 0.3)
        }

        let red = ansi(1), green = ansi(2), yellow = ansi(3), blue = ansi(4)
        let magenta = ansi(5), cyan = ansi(6), pink = ansi(13)
        let claude = magenta
        let inactive = gray(0.55)
        let promptBorder = gray(0.45)
        let remember = blue
        let lineTint = dark ? 0.22 : 0.16
        let wordTint = dark ? 0.45 : 0.35
        let dimmedTint = dark ? 0.10 : 0.08

        let overrides: [(String, GhosttyThemeRGB)] = [
            ("claude", claude),
            ("claudeShimmer", shimmer(claude)),
            ("text", fg),
            ("inverseText", bg),
            ("inactive", inactive),
            ("inactiveShimmer", shimmer(inactive)),
            ("subtle", gray(0.3)),
            ("suggestion", ansi(12)),
            ("permission", blue),
            ("permissionShimmer", shimmer(blue)),
            ("remember", remember),
            ("success", green),
            ("error", red),
            ("warning", yellow),
            ("warningShimmer", shimmer(yellow)),
            ("merged", magenta),
            ("promptBorder", promptBorder),
            ("promptBorderShimmer", shimmer(promptBorder)),
            ("planMode", cyan),
            ("autoAccept", green),
            ("bashBorder", pink),
            ("ide", blue),
            ("fastMode", yellow),
            ("fastModeShimmer", shimmer(yellow)),
            ("diffAdded", tint(green, lineTint)),
            ("diffRemoved", tint(red, lineTint)),
            ("diffAddedDimmed", tint(green, dimmedTint)),
            ("diffRemovedDimmed", tint(red, dimmedTint)),
            ("diffAddedWord", tint(green, wordTint)),
            ("diffRemovedWord", tint(red, wordTint)),
            ("userMessageBackground", gray(0.08)),
            ("userMessageBackgroundHover", gray(0.13)),
            ("bashMessageBackgroundColor", tint(pink, 0.1)),
            ("memoryBackgroundColor", tint(remember, 0.1)),
            ("selectionBg", palette.selectionBackground),
            ("rate_limit_fill", claude),
            ("rate_limit_empty", gray(0.3)),
            ("briefLabelYou", blue),
            ("briefLabelClaude", claude),
            ("red_FOR_SUBAGENTS_ONLY", red),
            ("blue_FOR_SUBAGENTS_ONLY", blue),
            ("green_FOR_SUBAGENTS_ONLY", green),
            ("yellow_FOR_SUBAGENTS_ONLY", yellow),
            ("purple_FOR_SUBAGENTS_ONLY", magenta),
            ("orange_FOR_SUBAGENTS_ONLY", red.mixed(toward: yellow, amount: 0.5)),
            ("pink_FOR_SUBAGENTS_ONLY", pink),
            ("cyan_FOR_SUBAGENTS_ONLY", cyan),
        ]

        return AgentThemeJSON.object([
            ("name", .string(name)),
            ("base", .string(dark ? "dark" : "light")),
            ("overrides", .object(overrides.map { ($0.0, .string($0.1.hexString)) }, inline: false)),
        ], inline: false).rendered()
    }
}
