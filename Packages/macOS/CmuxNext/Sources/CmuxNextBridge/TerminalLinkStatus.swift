public import Foundation

/// Why a terminal view lost its daemon stream (shown in its placeholder).
public nonisolated enum TerminalDisconnectReason: Hashable, Sendable {
    /// The daemon ended the stream (`detached`).
    case streamEnded
    /// The attach connection closed.
    case connectionLost
    /// An attach did not complete.
    case attachFailed
    /// The view fell behind again and again (overflow limit).
    case fellBehind
}

/// What a terminal view shows about its daemon link.
public nonisolated enum TerminalLinkStatus: Hashable, Sendable {
    case connected
    /// The last screen stays; `reconnecting` while one re-attach runs.
    case disconnected(TerminalDisconnectReason, reconnecting: Bool)
    /// The terminal's process ended; the view never re-attaches.
    case exited
}

/// The cursor shape a fresh Ghostty surface starts with (the user's
/// `cursor-style` and `cursor-style-blink`), so a replay's cursor restore
/// never overrides the user's config with the daemon's default.
public nonisolated struct TerminalCursorDefault: Hashable, Sendable {
    /// `block`, `bar`, `underline` or `block_hollow`.
    public var style: String
    /// nil: Ghostty's default (blinking).
    public var blink: Bool?

    public init(style: String, blink: Bool?) {
        self.style = style
        self.blink = blink
    }

    public static let ghostty = TerminalCursorDefault(style: "block", blink: nil)

    /// DECSCUSR restoring a replay's cursor, or nothing when the replay has
    /// no shape or its shape is this default (the surface already shows it).
    public func restore(style replayStyle: String?, blink replayBlink: Bool?) -> Data {
        guard let replayStyle else { return Data() }
        let blinks = replayBlink ?? (blink ?? true)
        if replayStyle == style, blinks == (blink ?? true) { return Data() }
        let steady: Int
        switch replayStyle {
        case "block": steady = 2
        case "underline": steady = 4
        case "bar": steady = 6
        default: return Data()
        }
        return Data("\u{1B}[\(blinks ? steady - 1 : steady) q".utf8)
    }
}
