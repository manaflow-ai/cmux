import Foundation

extension RemoteTmuxControlConnection {
    typealias ConnectionState = RemoteTmuxConnectionState
    typealias PaneForegroundState = RemoteTmuxPaneForegroundState
    typealias Snapshot = RemoteTmuxControlConnectionSnapshot
    typealias CommandKind = RemoteTmuxControlCommandKind
    typealias PostAttachAction = RemoteTmuxPostAttachAction

    /// Opaque token identifying a registered observer (pass to ``removeObserver(_:)``).
    typealias ObserverToken = UUID

    /// `true` once the connection has permanently ended (genuine tmux `%exit`, a
    /// session discovered gone on reconnect, or a deliberate ``stop()``). A
    /// transient transport loss is `.reconnecting`, NOT ended — so callers that
    /// guard on `!exited` keep treating a reconnecting connection as alive.
    var exited: Bool { connectionState == .ended }

    /// The last size ANY writer requested via ``setClientSize(columns:rows:)`` —
    /// the shared dedup baseline for every sizing writer on this connection. A
    /// writer must never dedup against a private cache of what IT last pushed:
    /// the client size is shared session state, and after another writer moves
    /// it, a stale private cache swallows exactly the re-push that would
    /// reconcile the window (the mismatch then persists with no recovery path).
    var lastRequestedClientSize: (columns: Int, rows: Int)? { lastClientSize }

    /// Registers a consumer's callbacks and returns a token to deregister them.
    ///
    /// Multiple consumers (e.g. a mirrored workspace and a single-pane display
    /// tab) can observe the same shared connection concurrently; every callback
    /// fires for every event. Pass the returned token to ``removeObserver(_:)``
    /// when the consumer goes away.
    ///
    /// - Parameters:
    ///   - onPaneOutput: receives every `%output` (raw, octal-unescaped bytes).
    ///   - onPaneCwd: receives a pane's working directory (`pane_current_path`),
    ///     both the initial value and live changes (see ``requestPanePath(paneId:)``
    ///     and ``subscribePanePath(paneId:)``).
    ///   - onPaneReflow: receives a pane's reflow classification (`true` = suppress
    ///     reflow on resize for alt-screen / inline-TUI panes like claude; `false`
    ///     = a plain shell whose primary-screen scrollback may reflow), both the
    ///     initial value and live changes (see ``subscribePaneReflow(paneId:)``).
    ///   - onActivePaneChanged: fires when a window's active pane changes
    ///     (`%window-pane-changed`), so consumers can re-project per-pane state
    ///     (e.g. the active pane's directory) onto the window's tab.
    ///   - onSessionChanged: fires when tmux confirms a session name change via
    ///     `%session-changed` or `%session-renamed`.
    ///   - onTopologyChanged: fires when the window/pane topology changes.
    ///   - onReconnectReady: fires after reconnect attach drainage and reseeding,
    ///     when observers may safely schedule commands against fresh topology.
    ///   - onExit: fires once when the connection PERMANENTLY ends (a genuine tmux
    ///     `%exit`, or a session found gone on reconnect). A transient transport loss
    ///     does NOT fire this — the connection reconnects instead.
    ///   - onConnectionStateChanged: fires on every ``ConnectionState`` transition
    ///     (e.g. `.connected` → `.reconnecting` on a transport loss), so consumers
    ///     can show a disconnected/reconnecting indicator without tearing down.
    @discardableResult
    func addObserver(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)? = nil,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)? = nil,
        onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)? = nil,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)? = nil,
        onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)? = nil,
        onTopologyChanged: (() -> Void)? = nil,
        onReconnectReady: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onConnectionStateChanged: ((ConnectionState) -> Void)? = nil
    ) -> ObserverToken {
        observers.add(
            onPaneOutput: onPaneOutput,
            onPaneCwd: onPaneCwd,
            onPaneReflow: onPaneReflow,
            onActivePaneChanged: onActivePaneChanged,
            onSessionChanged: onSessionChanged,
            onTopologyChanged: onTopologyChanged,
            onReconnectReady: onReconnectReady,
            onExit: onExit,
            onConnectionStateChanged: onConnectionStateChanged
        )
    }

    /// Deregisters the callbacks registered under `token`.
    func removeObserver(_ token: ObserverToken) {
        observers.remove(token)
    }
}
