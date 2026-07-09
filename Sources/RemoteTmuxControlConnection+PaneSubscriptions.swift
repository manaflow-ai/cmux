import Foundation

extension RemoteTmuxControlConnection {


    /// One-shot query of a pane's working directory (`pane_current_path`),
    /// delivered to the cwd observers. Guarantees an initial folder for the
    /// mirrored tab even on tmux builds without control-mode subscriptions.
    func requestPanePath(paneId: Int) {
        sendInternal(
            "display-message -p -t %\(paneId) -F \"#{pane_current_path}\"",
            kind: .panePath(paneId)
        )
    }


    /// The exact `refresh-client -B` line that subscribes `paneId`'s working
    /// directory. The `name:target:format` argument MUST stay double-quoted:
    /// tmux's command parser rejects an unquoted `#{…}` mid-argument with
    /// `parse error: syntax error` (verified on tmux 3.6a), and because the
    /// result FIFO drops `%error` blocks the subscription would silently never
    /// exist — the mirrored tab's folder would just never update.
    static func panePathSubscriptionCommand(paneId: Int) -> String {
        "refresh-client -B \"\(cwdSubscriptionPrefix)\(paneId):%\(paneId):#{pane_current_path}\""
    }


    /// Subscribes to live `pane_current_path` changes for `paneId` via tmux
    /// control-mode `refresh-client -B`, so a remote `cd` updates the mirrored
    /// tab's folder without polling. tmux emits the value once on subscribe and
    /// again on every change as `%subscription-changed cmux_cwd_<paneId> … : <path>`.
    /// Best-effort: on tmux builds that don't support subscriptions the command is
    /// a no-op and ``requestPanePath(paneId:)`` still supplies the initial folder.
    func subscribePanePath(paneId: Int) {
        send(Self.panePathSubscriptionCommand(paneId: paneId))
    }


    /// Removes the live `pane_current_path` subscription for `paneId` (issued once
    /// the pane is gone). tmux also drops a dead pane's subscriptions on its own;
    /// this keeps the client's subscription set tidy across split/close churn.
    func unsubscribePanePath(paneId: Int) {
        send("refresh-client -B \(Self.cwdSubscriptionPrefix)\(paneId)")
    }


    /// One-shot query of a pane's reflow classification (`#{alternate_on}` +
    /// `#{pane_current_command}`), delivered to the reflow observers. This is the
    /// REQUIRED initial classifier — `subscribePaneReflow` only guarantees *live*
    /// updates, and on tmux builds where the `-B` subscription doesn't deliver this
    /// combined value the surface would otherwise stay at its safe no-reflow default
    /// forever (shells never reflow). Mirrors ``requestPanePath(paneId:)`` exactly
    /// (a `display-message` always works where a subscription might not).
    func requestPaneReflow(paneId: Int) {
        sendInternal(
            "display-message -p -t %\(paneId) -F \""
                + "#{alternate_on}\(PaneForegroundState.fieldSeparator)#{pane_current_command}\"",
            kind: .paneReflow(paneId)
        )
    }


    /// Classifies a raw `#{alternate_on}|#{pane_current_command}` value (from the
    /// one-shot query or a live subscription), records it as the pane's foreground
    /// state (for the close-confirmation check), and emits the no-reflow decision.
    /// No-reflow when on the alternate screen OR the foreground command isn't a known
    /// plain shell; defaults to no-reflow on an empty/unparseable value (safe).
    func classifyAndEmitReflow(paneId: Int, rawValue: String, source: String) {
        let state = PaneForegroundState(rawValue: rawValue)
        paneForegroundStates[paneId] = state
        let noReflow = state.suppressesReflow
        #if DEBUG
        cmuxDebugLog(
            "remote.reflow.classify pane=\(paneId) src=\(source) raw=\"\(rawValue.trimmingCharacters(in: .whitespacesAndNewlines))\" "
                + "alt=\(state.alternateOn ? 1 : 0) cmd=\"\(state.command)\" noReflow=\(noReflow ? 1 : 0)"
        )
        #endif
        observers.emitPaneReflow(paneId, noReflow)
    }


    /// The exact `refresh-client -B` line that subscribes `paneId`'s foreground
    /// classification. Same quoting requirement as
    /// ``panePathSubscriptionCommand(paneId:)`` — unquoted, tmux rejects the
    /// `#{…}` with a (silently dropped) parse error and the live classification
    /// never arrives, so a pane that starts a command after its seed keeps its
    /// stale idle-shell state and the close confirmation never fires.
    static func paneReflowSubscriptionCommand(paneId: Int) -> String {
        "refresh-client -B \"\(reflowSubscriptionPrefix)\(paneId):%\(paneId):"
            + "#{alternate_on}\(PaneForegroundState.fieldSeparator)#{pane_current_command}\""
    }


    /// Subscribes to live reflow-classification changes for `paneId` via tmux
    /// control-mode `refresh-client -B`. The subscribed value is
    /// `#{alternate_on}|#{pane_current_command}`; tmux emits it once on subscribe
    /// and again whenever it changes, so a pane that switches between a plain shell
    /// and an inline TUI (e.g. bash → node when claude launches) is reclassified
    /// without polling. The mirror surface uses this to decide whether to reflow its
    /// primary screen on resize (shells reflow; alt-screen / inline-TUI panes do
    /// not), and the close confirmation uses it to track the active foreground
    /// command. Best-effort: on tmux builds without subscriptions this is a no-op and
    /// the surface keeps its safe no-reflow default. See ``subscriptionChanged``
    /// handling for the parse, and ``PaneForegroundState/plainShellCommands`` for the policy.
    func subscribePaneReflow(paneId: Int) {
        send(Self.paneReflowSubscriptionCommand(paneId: paneId))
    }


    /// Removes the live reflow-classification subscription for `paneId` (issued once
    /// the pane is gone), mirroring ``unsubscribePanePath(paneId:)``.
    func unsubscribePaneReflow(paneId: Int) {
        send("refresh-client -B \(Self.reflowSubscriptionPrefix)\(paneId)")
    }


    /// The `list-panes` line behind ``queryWindowActivity(windowId:completion:)``.
    static func windowActivityQueryCommand(windowId: Int) -> String {
        "list-panes -t @\(windowId) -F \"\(activityQueryFormat)\""
    }


    /// The `display-message` line behind ``queryPaneActivity(paneId:completion:)``.
    static func paneActivityQueryCommand(paneId: Int) -> String {
        "display-message -p -t %\(paneId) -F \"\(activityQueryFormat)\""
    }


    /// Live, close-time query of every pane's foreground state in `windowId`.
    /// tmux evaluates `pane_current_command` AT QUERY TIME, so a command started
    /// the instant before ⌘W is already visible — unlike the `%subscription-changed`
    /// cache, which tmux only re-checks about once a second. Results also refresh
    /// ``paneForegroundStates`` so the synchronous consumers (batch close,
    /// workspace close, quit warning) get the freshness for free. `completion` is
    /// called exactly once, on the main actor; `nil` means the query could not be
    /// issued or the stream reset first (caller falls back to the cache).
    func queryWindowActivity(windowId: Int, completion: @escaping ([Int: PaneForegroundState]?) -> Void) {
        sendActivityQuery(Self.windowActivityQueryCommand(windowId: windowId), completion: completion)
    }


    /// Single-pane variant of ``queryWindowActivity(windowId:completion:)``, for
    /// the multi-pane mirror's pane-header ✕ close.
    func queryPaneActivity(paneId: Int, completion: @escaping ([Int: PaneForegroundState]?) -> Void) {
        sendActivityQuery(Self.paneActivityQueryCommand(paneId: paneId), completion: completion)
    }


    func sendActivityQuery(
        _ command: String, completion: @escaping ([Int: PaneForegroundState]?) -> Void
    ) {
        guard connectionState == .connected else {
            completion(nil)
            return
        }
        let token = UUID()
        activityQueryCompletions[token] = completion
        guard sendInternal(command, kind: .activityQuery(token)) else {
            // The stream could not accept the query, so no result can correlate.
            // Fail now and let the close decision proceed on the cached state.
            activityQueryCompletions.removeValue(forKey: token)?(nil)
            return
        }
    }


    /// Parses one activity-query line (``activityQueryFormat``):
    /// `%<paneId>|<alternate_on>|<pane_current_command>`. `nil` for an
    /// unparseable line — the caller treats that pane as unclassified.
    /// `maxSplits: 1` is deliberate (NOT 2): this strips only the `%paneId`
    /// prefix, and ``PaneForegroundState/init(rawValue:)`` applies its own
    /// `maxSplits: 1` for the second field — so a `|` inside a command name
    /// stays in the command instead of truncating it.
    static func parseActivityQueryLine(_ line: String) -> (paneId: Int, state: PaneForegroundState)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: PaneForegroundState.fieldSeparator, maxSplits: 1, omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let paneId = RemoteTmuxControlStreamParser.id(parts[0], sigil: "%") else { return nil }
        return (paneId, PaneForegroundState(rawValue: String(parts[1])))
    }


    /// Fails every in-flight activity query — called whenever the control stream
    /// becomes unusable (reconnect begins, deliberate stop, genuine `%exit`), so
    /// a pending close decision falls back to the cached classification.
    func failPendingActivityQueries() {
        guard !activityQueryCompletions.isEmpty else { return }
        let completions = Array(activityQueryCompletions.values)
        activityQueryCompletions.removeAll()
        for completion in completions { completion(nil) }
    }
}
