import CmuxRemoteWorkspace
import Foundation

/// Pure builders for the tmux control-mode command strings that
/// ``RemoteTmuxControlConnection`` writes, plus the parser for the activity-query
/// lines it reads back. Held as a value by the connection and called as
/// `commandBuilder.xxx(...)`; carries only the constant subscription-name prefixes
/// and the activity-query format, so every method is a pure transform of its
/// arguments. Defined once here so the writer side (subscribe) and the reader
/// side (unsubscribe / `%subscription-changed` routing / activity parse) can't
/// drift on those prefixes or on the query format.
struct RemoteTmuxControlCommandBuilder: Sendable {
    /// Subscription-name prefix for per-pane `pane_current_path` (`refresh-client -B`).
    /// The tmux pane id is appended so an inbound `%subscription-changed` can be
    /// routed back to its pane; defined once so the writer and reader can't drift.
    let cwdSubscriptionPrefix = "cmux_cwd_"

    /// Subscription-name prefix for per-pane reflow classification
    /// (`refresh-client -B`). The subscribed format is
    /// `#{alternate_on}<sep>#{pane_current_command}`; tmux emits it on subscribe
    /// and on every change, so launching/exiting an app (bash → node when claude
    /// starts) re-classifies the pane live. The tmux pane id is appended for
    /// routing, mirroring ``cwdSubscriptionPrefix``.
    let reflowSubscriptionPrefix = "cmux_reflow_"

    /// Format for close-time activity queries: the pane id (for cache refresh and
    /// multi-pane correlation) plus the same `alternate_on`/`pane_current_command`
    /// pair the reflow subscription streams. Quoted by the command builders — see
    /// ``panePathSubscriptionCommand(paneId:)`` for why the quoting is load-bearing.
    private let activityQueryFormat = "#{pane_id}\(RemoteTmuxPaneForegroundState.fieldSeparator)"
        + "#{alternate_on}\(RemoteTmuxPaneForegroundState.fieldSeparator)#{pane_current_command}"

    /// How many scrollback lines ``capturePaneCommand(paneId:)`` seeds (`-S -<N>`)
    /// so a freshly-mounted mirror tab is scrollable immediately. On an
    /// alternate-screen pane there is no history, so tmux clamps to the visible
    /// alt screen — harmless.
    let captureScrollbackLines = 5_000

    /// The exact `refresh-client -B` line that subscribes `paneId`'s working
    /// directory. The `name:target:format` argument MUST stay double-quoted:
    /// tmux's command parser rejects an unquoted `#{…}` mid-argument with
    /// `parse error: syntax error` (verified on tmux 3.6a), and because the
    /// result FIFO drops `%error` blocks the subscription would silently never
    /// exist — the mirrored tab's folder would just never update.
    func panePathSubscriptionCommand(paneId: Int) -> String {
        "refresh-client -B \"\(cwdSubscriptionPrefix)\(paneId):%\(paneId):#{pane_current_path}\""
    }

    /// The exact `refresh-client -B` line that subscribes `paneId`'s foreground
    /// classification. Same quoting requirement as
    /// ``panePathSubscriptionCommand(paneId:)`` — unquoted, tmux rejects the
    /// `#{…}` with a (silently dropped) parse error and the live classification
    /// never arrives, so a pane that starts a command after its seed keeps its
    /// stale idle-shell state and the close confirmation never fires.
    func paneReflowSubscriptionCommand(paneId: Int) -> String {
        "refresh-client -B \"\(reflowSubscriptionPrefix)\(paneId):%\(paneId):"
            + "#{alternate_on}\(RemoteTmuxPaneForegroundState.fieldSeparator)#{pane_current_command}\""
    }

    /// The `list-panes` line behind ``RemoteTmuxControlConnection/queryWindowActivity(windowId:completion:)``.
    func windowActivityQueryCommand(windowId: Int) -> String {
        "list-panes -t @\(windowId) -F \"\(activityQueryFormat)\""
    }

    /// The `display-message` line behind ``RemoteTmuxControlConnection/queryPaneActivity(paneId:completion:)``.
    func paneActivityQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"\(activityQueryFormat)\""
    }

    /// Parses one activity-query line (``activityQueryFormat``):
    /// `%<paneId>|<alternate_on>|<pane_current_command>`. `nil` for an
    /// unparseable line — the caller treats that pane as unclassified.
    /// `maxSplits: 1` is deliberate (NOT 2): this strips only the `%paneId`
    /// prefix, and ``RemoteTmuxPaneForegroundState/init(rawValue:)`` applies its own
    /// `maxSplits: 1` for the second field — so a `|` inside a command name
    /// stays in the command instead of truncating it.
    func parseActivityQueryLine(_ line: String) -> (paneId: Int, state: RemoteTmuxPaneForegroundState)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: RemoteTmuxPaneForegroundState.fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let paneId = RemoteTmuxControlStreamParser.id(parts[0], sigil: "%") else { return nil }
        return (paneId, RemoteTmuxPaneForegroundState(rawValue: String(parts[1])))
    }

    /// Hex-encodes `data` as the space-separated byte arguments tmux `send-keys -H`
    /// expects, which is binary-safe and needs no shell quoting.
    func hexByteArguments(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 3 - 1)
        for byte in data {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: " ")) }
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The `set-buffer`/`paste-buffer` command pair that pastes `text` into
    /// `paneId` via a dedicated, immediately-deleted (`-d`) per-pane buffer.
    /// `nil` for empty `text`. The `--` and `shellSingleQuoted` quoting keep an
    /// option-looking path (e.g. `-n …`) from being parsed as a tmux flag.
    func pastePaneCommands(paneId: Int, text: String)
        -> (setBuffer: String, pasteBuffer: String)?
    {
        guard !text.isEmpty else { return nil }
        let buffer = "cmux-paste-\(paneId)"
        return (
            setBuffer: "set-buffer -b \(buffer) -- \(RemoteTmuxHost.shellSingleQuoted(text))",
            pasteBuffer: "paste-buffer -p -d -b \(buffer) -t %\(paneId)"
        )
    }

    /// The `list-windows` line behind ``RemoteTmuxControlConnection/requestWindows()``.
    /// `#{window_name}` is placed last because it can contain spaces, while the id
    /// and layout tokens never do — so the result parses as
    /// `@id <layout> <name with spaces…>`.
    func listWindowsCommand() -> String {
        "list-windows -F \"#{window_id} #{window_layout} #{window_name}\""
    }

    /// The `display-message` line behind ``RemoteTmuxControlConnection/capturePane(paneId:)``
    /// that queries whether `paneId` is on the alternate screen (`#{alternate_on}`),
    /// so the mirror surface enters alt before painting the captured rows.
    func paneAlternateScreenQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"#{alternate_on}\""
    }

    /// The `capture-pane` line behind ``RemoteTmuxControlConnection/capturePane(paneId:)``.
    /// `-S -<N>` seeds ``captureScrollbackLines`` of scrollback history (not just the
    /// visible screen) so the mirrored tab is scrollable immediately on attach.
    func capturePaneCommand(paneId: Int) -> String {
        "capture-pane -p -e -S -\(captureScrollbackLines) -t %\(paneId)"
    }

    /// The `display-message` line behind ``RemoteTmuxControlConnection/capturePane(paneId:)``
    /// that queries a pane's terminal STATE (cursor, scroll region, DEC private
    /// modes, mouse tracking). Sent after `capture-pane` so it applies on top of the
    /// painted rows.
    func paneStateQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \""
            + "cursor_x=#{cursor_x},cursor_y=#{cursor_y},"
            + "scroll_region_upper=#{scroll_region_upper},scroll_region_lower=#{scroll_region_lower},"
            + "cursor_flag=#{cursor_flag},insert_flag=#{insert_flag},"
            + "keypad_cursor_flag=#{keypad_cursor_flag},keypad_flag=#{keypad_flag},"
            + "wrap_flag=#{wrap_flag},origin_flag=#{origin_flag},pane_height=#{pane_height},"
            + "mouse_all_flag=#{mouse_all_flag},mouse_button_flag=#{mouse_button_flag},"
            + "mouse_standard_flag=#{mouse_standard_flag},"
            + "mouse_sgr_flag=#{mouse_sgr_flag},mouse_utf8_flag=#{mouse_utf8_flag}\""
    }

    /// The one-shot `display-message` line behind ``RemoteTmuxControlConnection/requestPanePath(paneId:)``,
    /// querying `paneId`'s working directory (`pane_current_path`).
    func panePathQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"#{pane_current_path}\""
    }

    /// The `refresh-client -B` line behind ``RemoteTmuxControlConnection/unsubscribePanePath(paneId:)``
    /// that removes `paneId`'s live `pane_current_path` subscription, mirroring the
    /// name built by ``panePathSubscriptionCommand(paneId:)``.
    func panePathUnsubscribeCommand(paneId: Int) -> String {
        "refresh-client -B \(cwdSubscriptionPrefix)\(paneId)"
    }

    /// The one-shot `display-message` line behind ``RemoteTmuxControlConnection/requestPaneReflow(paneId:)``,
    /// querying `paneId`'s reflow classification (`#{alternate_on}` +
    /// `#{pane_current_command}`). Mirrors the format streamed by
    /// ``paneReflowSubscriptionCommand(paneId:)``.
    func paneReflowQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \""
            + "#{alternate_on}\(RemoteTmuxPaneForegroundState.fieldSeparator)#{pane_current_command}\""
    }

    /// The `refresh-client -B` line behind ``RemoteTmuxControlConnection/unsubscribePaneReflow(paneId:)``
    /// that removes `paneId`'s live reflow-classification subscription, mirroring the
    /// name built by ``paneReflowSubscriptionCommand(paneId:)``.
    func paneReflowUnsubscribeCommand(paneId: Int) -> String {
        "refresh-client -B \(reflowSubscriptionPrefix)\(paneId)"
    }

    /// The `send-keys -H` line behind ``RemoteTmuxControlConnection/sendKeys(paneId:data:)``,
    /// delivering `data` as the hex byte arguments from ``hexByteArguments(_:)`` —
    /// binary-safe and needing no shell quoting.
    func sendKeysCommand(paneId: Int, data: Data) -> String {
        "send-keys -t %\(paneId) -H \(hexByteArguments(data))"
    }

    /// The `refresh-client -C` line that sets the control client's grid size, used
    /// by ``RemoteTmuxControlConnection`` to (re-)apply the last client size on
    /// reconnect and after attach.
    func clientResizeCommand(columns: Int, rows: Int) -> String {
        "refresh-client -C \(columns)x\(rows)"
    }
}
