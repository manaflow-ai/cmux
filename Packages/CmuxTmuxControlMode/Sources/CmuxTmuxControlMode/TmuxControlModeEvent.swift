import Foundation

/// A single decoded event from a `tmux -CC` (control mode) gateway stream.
///
/// The control protocol multiplexes two things on one stream: command
/// request/response blocks (`%begin` … `%end`/`%error`) and asynchronous
/// `%`-prefixed notifications. tmux guarantees a notification never appears
/// inside a command block, so the parser is a simple in-block / out-of-block
/// state machine. See https://github.com/tmux/tmux/wiki/Control-Mode.
public enum TmuxControlModeEvent: Equatable, Sendable {
    /// `%begin <time> <number> <flags>` — start of a command response block.
    case begin(number: Int)

    /// A completed command response block (`%begin` … `%end`/`%error`).
    /// `output` is the verbatim lines tmux emitted for the command, in order.
    /// `isError` is true when the block was terminated by `%error`.
    case commandResult(number: Int, output: [String], isError: Bool)

    /// `%output %<pane> <data>` — live bytes a pane's program wrote.
    /// `bytes` is already octal-unescaped back to the raw byte stream.
    case output(paneID: String, bytes: [UInt8])

    /// `%layout-change <window> <layout> <visible-layout> <flags>`.
    case layoutChange(window: String, layout: String, visibleLayout: String?, flags: String?)

    /// `%window-add @<window>`.
    case windowAdd(window: String)
    /// `%window-close @<window>` / `%unlinked-window-close`.
    case windowClose(window: String)
    /// `%window-renamed @<window> <name>`.
    case windowRenamed(window: String, name: String)
    /// `%window-pane-changed @<window> %<pane>`.
    case windowPaneChanged(window: String, pane: String)

    /// `%session-changed $<session> <name>`.
    case sessionChanged(session: String, name: String)
    /// `%sessions-changed`.
    case sessionsChanged

    /// `%pane-mode-changed %<pane>` (copy-mode entered/left server-side).
    case paneModeChanged(pane: String)

    /// `%exit [reason]` — the control client is ending.
    case exit(reason: String?)
    /// `%client-detached <client>` — this client detached but the server lives on.
    case clientDetached

    /// Any other `%…` notification we do not model explicitly.
    /// `name` excludes the leading `%`.
    case notification(name: String, arguments: [String])
}
