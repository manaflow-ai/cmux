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
    /// `ghostty_config_window_padding_s`: two u32 points. Mirrored here so
    /// the read compiles against any GhosttyKit; `configGet` reports false
    /// when the linked libghostty cannot return the key.
    private struct CPadding: BitwiseCopyable {
        var topLeft: UInt32 = 0
        var bottomRight: UInt32 = 0
    }

    /// The padding in the config the surfaces use now.
    public var terminalPadding: TerminalPadding {
        guard let config else { return .ghosttyDefault }
        return Self.terminalPadding(of: config)
    }

    static func terminalPadding(of config: ghostty_config_t) -> TerminalPadding {
        var padding = TerminalPadding.ghosttyDefault
        var x = CPadding()
        if configGet(config, &x, key: "window-padding-x") {
            padding.leading = CGFloat(x.topLeft)
            padding.trailing = CGFloat(x.bottomRight)
        }
        var y = CPadding()
        if configGet(config, &y, key: "window-padding-y") {
            padding.top = CGFloat(y.topLeft)
            padding.bottom = CGFloat(y.bottomRight)
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
