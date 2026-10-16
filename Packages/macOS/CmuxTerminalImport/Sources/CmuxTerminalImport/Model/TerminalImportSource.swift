/// A terminal emulator whose settings `cmux import` can read.
public enum TerminalImportSource: String, CaseIterable, Sendable {
    /// iTerm2, read from the `com.googlecode.iterm2` preferences domain.
    case iTerm2 = "iterm2"
    /// macOS Terminal, read from the `com.apple.Terminal` preferences domain.
    case terminalApp = "terminal"
    /// Alacritty, read from `alacritty.toml` or the legacy `alacritty.yml`.
    case alacritty
    /// Kitty, read from `kitty.conf` and the files it includes.
    case kitty
    /// WezTerm, read from static assignments in `wezterm.lua`.
    case wezTerm = "wezterm"
    /// Warp, read from a custom theme YAML file.
    case warp
    /// Ghostty, whose config cmux already loads, so there is nothing to import.
    case ghostty

    /// The name printed in listings and reports.
    public var displayName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .terminalApp: return "Terminal"
        case .alacritty: return "Alacritty"
        case .kitty: return "Kitty"
        case .wezTerm: return "WezTerm"
        case .warp: return "Warp"
        case .ghostty: return "Ghostty"
        }
    }

    /// Resolves a command-line source name, accepting a few common spellings.
    ///
    /// - Parameter argument: The user's spelling, such as `iterm`, `Terminal.app` or `wezterm`.
    /// - Returns: The matching source, or `nil` when the name is unknown.
    public init?(argument: String) {
        let folded = argument
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".app", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch folded {
        case "iterm", "iterm2": self = .iTerm2
        case "terminal", "appleterminal", "macosterminal": self = .terminalApp
        case "alacritty": self = .alacritty
        case "kitty": self = .kitty
        case "wezterm": self = .wezTerm
        case "warp": self = .warp
        case "ghostty": self = .ghostty
        default: return nil
        }
    }
}
