public import CoreGraphics
import CmuxNextDesign
import GhosttyNextKit

/// The terminal's padding inside its pane's content border
/// (`window-padding-x`, `window-padding-y`, `window-padding-balance`).
/// cmux loads `cmuxDefault` before the user's Ghostty files, so the first
/// cell sits `PaneChromeMetrics.terminalTextInset` inside the border unless
/// the user set their own padding, which then applies as written.
public struct TerminalPadding: Equatable, Sendable {
    public var leading: CGFloat
    public var trailing: CGFloat
    public var top: CGFloat
    public var bottom: CGFloat
    /// Ghostty centers the grid in the leftover space.
    public var balanced: Bool

    /// Ghostty's defaults (2 pt on every side, no balance).
    public static let ghosttyDefault = TerminalPadding(leading: 2, trailing: 2, top: 2, bottom: 2, balanced: false)

    /// cmux's default: `PaneChromeMetrics.terminalTextInset` on every side,
    /// no balance, so the grid's leftover goes to the right and bottom and
    /// the left and top insets are exact.
    public static let cmuxDefault: TerminalPadding = {
        let inset = PaneChromeMetrics.terminalTextInset
        return TerminalPadding(leading: inset, trailing: inset, top: inset, bottom: inset, balanced: false)
    }()

    /// Config lines for `cmuxDefault`, loaded before the user's files.
    nonisolated static var cmuxDefaultConfigLines: [String] {
        let inset = Int(PaneChromeMetrics.terminalTextInset)
        return ["window-padding-x = \(inset)", "window-padding-y = \(inset)", "window-padding-balance = false"]
    }
}

extension GhosttyRuntime {
    /// The padding in the config the surfaces use now.
    public var terminalPadding: TerminalPadding {
        guard let config else { return .cmuxDefault }
        // SAFETY: the runtime's live applied config (GhosttyRuntime.config).
        return unsafe Self.terminalPadding(of: config)
    }

    /// The padding of `config`, a live handle the caller holds for the call.
    static func terminalPadding(of config: ghostty_config_t) -> TerminalPadding {
        var padding = TerminalPadding.ghosttyDefault
        // ghostty_config_window_padding_s (manaflow-ai/ghostty#251).
        var x = ghostty_config_window_padding_s()
        // SAFETY: the caller's live config; window-padding-x is a ghostty_config_window_padding_s.
        if unsafe configGet(config, &x, key: "window-padding-x") {
            padding.leading = CGFloat(x.top_left)
            padding.trailing = CGFloat(x.bottom_right)
        }
        var y = ghostty_config_window_padding_s()
        // SAFETY: as above, for window-padding-y.
        if unsafe configGet(config, &y, key: "window-padding-y") {
            padding.top = CGFloat(y.top_left)
            padding.bottom = CGFloat(y.bottom_right)
        }
        // SAFETY: the caller's live config; window-padding-balance is a string (the enum's name).
        if let balance = unsafe configString(config, key: "window-padding-balance") {
            padding.balanced = balance != "false"
        }
        return padding
    }

    /// Loads cmux's padding default into `config`; call before the user's
    /// files so their `window-padding-*` lines win.
    nonisolated static func loadPaddingDefault(into config: ghostty_config_t) {
        for line in TerminalPadding.cmuxDefaultConfigLines {
            // SAFETY: the caller passes a live config.
            unsafe loadConfigLine(line, into: config, source: "cmux-next")
        }
    }

    /// The padding a user config made of `text` (Ghostty config lines)
    /// resolves to, loaded the way `loadConfig` loads it, for tests.
    static func terminalPadding(configText text: String) -> TerminalPadding? {
        // SAFETY: withScratchConfig's handle is live for each closure's call and stays in it.
        unsafe withScratchConfig(load: {
            // SAFETY: as above.
            unsafe loadPaddingDefault(into: $0)
            // SAFETY: as above.
            unsafe loadConfigLine(text, into: $0, source: "test")
        }, read: {
            // SAFETY: as above.
            unsafe terminalPadding(of: $0)
        })
    }
}
