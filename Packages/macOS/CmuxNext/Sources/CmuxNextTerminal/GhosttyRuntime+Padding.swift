public import CoreGraphics
import GhosttyKit

/// The terminal's own padding from the user's Ghostty config
/// (`window-padding-x`, `window-padding-y`, `window-padding-balance`), which
/// the pane chrome needs to line tab icons up with the first text column.
public struct TerminalPadding: Equatable, Sendable {
    public var leading: CGFloat
    public var trailing: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
    /// Ghostty centers the grid in the leftover space.
    public var balanced: Bool

    /// Ghostty's defaults (2 pt on every side, no balance).
    public static let ghosttyDefault = TerminalPadding(leading: 2, trailing: 2, top: 2, bottom: 2, balanced: false)
}

extension GhosttyRuntime {
    /// The padding in the config the surfaces use now.
    public var terminalPadding: TerminalPadding {
        guard let config else { return .ghosttyDefault }
        return Self.terminalPadding(of: config)
    }

    static func terminalPadding(of config: ghostty_config_t) -> TerminalPadding {
        var padding = TerminalPadding.ghosttyDefault
        // ghostty_config_window_padding_s (manaflow-ai/ghostty#251).
        var x = ghostty_config_window_padding_s()
        if configGet(config, &x, key: "window-padding-x") {
            padding.leading = CGFloat(x.top_left)
            padding.trailing = CGFloat(x.bottom_right)
        }
        var y = ghostty_config_window_padding_s()
        if configGet(config, &y, key: "window-padding-y") {
            padding.top = CGFloat(y.top_left)
            padding.bottom = CGFloat(y.bottom_right)
        }
        var balance: UnsafePointer<CChar>?
        if configGet(config, &balance, key: "window-padding-balance"), let balance {
            padding.balanced = String(cString: balance) != "false"
        }
        return padding
    }

    /// The padding a config made of `text` (Ghostty config lines) resolves
    /// to, for tests.
    static func terminalPadding(configText text: String) -> TerminalPadding? {
        guard let config = ghostty_config_new() else { return nil }
        defer { ghostty_config_free(config) }
        text.withCString { ghostty_config_load_string(config, $0, UInt(text.utf8.count), "test") }
        ghostty_config_finalize(config)
        return terminalPadding(of: config)
    }
}
