public import Foundation

/// A single parsed message from a remote tmux control-mode (`tmux -CC`) stream.
///
/// Produced by ``RemoteTmuxControlStreamParser``. Command responses (the output
/// between a `%begin`/`%end` pair) are coalesced into a single ``commandResult``
/// carrying the lines in between; everything else is an out-of-band notification.
public enum RemoteTmuxControlMessage: Sendable, Equatable {
    /// The `ESC P 1000 p` handshake that opens control mode.
    case enter

    /// Control mode ended (`%exit`), with tmux's optional reason.
    case exit(reason: String?)

    /// `%output %<pane> <data>` — terminal output for a pane. `data` is already
    /// octal-unescaped to its raw bytes, ready to feed into a display surface.
    case output(paneId: Int, data: Data)

    /// `%session-changed $<id> <name>` — the attached session changed.
    case sessionChanged(sessionId: Int, name: String)

    /// `%session-renamed [session-id] <name>` — the current session was renamed.
    /// tmux emits this for `rename-session` — distinct from `%session-changed`
    /// (which fires when the attached session switches). `name` preserves the
    /// documented name-only interpretation; `idBearingName` is the alternative
    /// interpretation when the first field looks like a tmux session id.
    case sessionRenamed(sessionId: Int?, name: String, idBearingName: String?)

    /// `%sessions-changed` — the set of sessions changed (re-list to refresh).
    case sessionsChanged

    /// `%window-add @<id>` — a window was added to the attached session.
    case windowAdd(windowId: Int)

    /// `%window-close @<id>` / `%unlinked-window-close @<id>` — a window closed.
    case windowClose(windowId: Int)

    /// `%window-renamed @<id> <name>` — a window was renamed.
    case windowRenamed(windowId: Int, name: String)

    /// `%layout-change @<id> <layout> <visible-layout> <flags>` — a window's
    /// pane layout changed. `layout` is the BASE tree (full tree even while
    /// zoomed); `visibleLayout` is what tmux displays (single-pane while
    /// zoomed); `zoomed` is derived from `Z` in the flags field. Raw layout
    /// strings parse with ``RemoteTmuxRawLayoutParser``.
    case layoutChange(windowId: Int, layout: String, visibleLayout: String?, zoomed: Bool)

    /// `%window-pane-changed @<id> %<pane>` — the active pane in a window changed.
    case windowPaneChanged(windowId: Int, paneId: Int)

    /// `%session-window-changed $<sid> @<wid>` — the active window in a session changed.
    case sessionWindowChanged(sessionId: Int, windowId: Int)

    /// `%subscription-changed <name> … : <value>` — a `refresh-client -B`
    /// subscription's value changed. cmux subscribes per-pane `pane_current_path`
    /// for live working-directory tracking. Parsed leniently: `name` is the first
    /// field and `value` is everything after the first ` : ` separator, so the
    /// version-variable middle fields (session/window/pane/flags) are ignored.
    case subscriptionChanged(name: String, value: String)

    /// The coalesced output of one command block (`%begin`…`%end`/`%error`).
    case commandResult(commandNumber: Int, lines: [String], isError: Bool)

    /// The control stream became unsafe to keep parsing, for example because an
    /// unterminated line or command block exceeded the parser's memory budget.
    case streamError(String)

    /// A recognized notification cmux does not act on (kept for diagnostics).
    case ignoredNotification(String)

    /// A line that could not be classified.
    case unparsed(String)
}
