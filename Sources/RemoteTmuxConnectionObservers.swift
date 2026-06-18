import Foundation

/// Multicast observer registry for one remote-tmux control connection.
///
/// A single ``RemoteTmuxControlConnection`` is shared by every consumer of the
/// same host+session (``RemoteTmuxController.attach`` reuses it), so events MUST
/// fan out to all consumers — a single overwritable closure silently cut off
/// whichever consumer wired up first. This type owns the per-event registries and
/// emits to every registered callback, snapshotting each registry before iterating
/// so a callback that unregisters itself (mutating the dictionary) can't trap on a
/// live collection.
@MainActor
final class RemoteTmuxConnectionObservers {
    /// Opaque token identifying a registered observer (pass to ``remove(_:)``).
    typealias Token = UUID

    private var paneOutputObservers: [Token: (_ paneId: Int, _ data: Data) -> Void] = [:]
    private var paneCwdObservers: [Token: (_ paneId: Int, _ path: String) -> Void] = [:]
    private var paneReflowObservers: [Token: (_ paneId: Int, _ noReflow: Bool) -> Void] = [:]
    private var activePaneObservers: [Token: (_ windowId: Int, _ paneId: Int) -> Void] = [:]
    private var sessionChangedObservers: [Token: (_ oldName: String, _ newName: String) -> Void] = [:]
    private var topologyObservers: [Token: () -> Void] = [:]
    private var exitObservers: [Token: () -> Void] = [:]
    private var stateObservers: [Token: (RemoteTmuxControlConnection.ConnectionState) -> Void] = [:]

    /// Registers a consumer's callbacks and returns a token to deregister them.
    ///
    /// Multiple consumers (e.g. a mirrored workspace and a single-pane display
    /// tab) can observe the same shared connection concurrently; every callback
    /// fires for every event. Pass the returned token to ``remove(_:)`` when the
    /// consumer goes away.
    ///
    /// - Parameters:
    ///   - onPaneOutput: receives every `%output` (raw, octal-unescaped bytes).
    ///   - onPaneCwd: receives a pane's working directory (`pane_current_path`),
    ///     both the initial value and live changes.
    ///   - onPaneReflow: receives a pane's reflow classification (`true` =
    ///     suppress reflow on resize, for alt-screen / inline-TUI panes like
    ///     claude; `false` = a plain shell whose primary-screen scrollback may
    ///     reflow), both the initial value and live changes.
    ///   - onActivePaneChanged: fires when a window's active pane changes
    ///     (`%window-pane-changed`), so consumers can re-project per-pane state
    ///     (e.g. the active pane's directory) onto the window's tab.
    ///   - onSessionChanged: fires when tmux confirms a session rename via
    ///     `%session-changed`; consumers must treat this as the authoritative
    ///     point for re-keying session-owned state.
    ///   - onTopologyChanged: fires when the window/pane topology changes.
    ///   - onExit: fires once when the connection PERMANENTLY ends (a genuine tmux
    ///     `%exit`, or a session found gone on reconnect). A transient transport loss
    ///     does NOT fire this — the connection reconnects instead.
    ///   - onConnectionStateChanged: fires on every connection-state transition
    ///     (e.g. `.connected` → `.reconnecting` on a transport loss), so consumers
    ///     can show a disconnected/reconnecting indicator without tearing down.
    /// - Returns: a ``Token`` to pass to ``remove(_:)``.
    func add(
        onPaneOutput: ((_ paneId: Int, _ data: Data) -> Void)?,
        onPaneCwd: ((_ paneId: Int, _ path: String) -> Void)?,
        onPaneReflow: ((_ paneId: Int, _ noReflow: Bool) -> Void)?,
        onActivePaneChanged: ((_ windowId: Int, _ paneId: Int) -> Void)?,
        onSessionChanged: ((_ oldName: String, _ newName: String) -> Void)?,
        onTopologyChanged: (() -> Void)?,
        onExit: (() -> Void)?,
        onConnectionStateChanged: ((RemoteTmuxControlConnection.ConnectionState) -> Void)?
    ) -> Token {
        let token = Token()
        if let onPaneOutput { paneOutputObservers[token] = onPaneOutput }
        if let onPaneCwd { paneCwdObservers[token] = onPaneCwd }
        if let onPaneReflow { paneReflowObservers[token] = onPaneReflow }
        if let onActivePaneChanged { activePaneObservers[token] = onActivePaneChanged }
        if let onSessionChanged { sessionChangedObservers[token] = onSessionChanged }
        if let onTopologyChanged { topologyObservers[token] = onTopologyChanged }
        if let onExit { exitObservers[token] = onExit }
        if let onConnectionStateChanged { stateObservers[token] = onConnectionStateChanged }
        return token
    }

    /// Deregisters the callbacks registered under `token`.
    func remove(_ token: Token) {
        paneOutputObservers[token] = nil
        paneCwdObservers[token] = nil
        paneReflowObservers[token] = nil
        activePaneObservers[token] = nil
        sessionChangedObservers[token] = nil
        topologyObservers[token] = nil
        exitObservers[token] = nil
        stateObservers[token] = nil
    }

    /// Fans `%output` bytes out to every pane-output observer.
    func emitPaneOutput(_ paneId: Int, _ data: Data) {
        // Snapshot before iterating: a callback may unregister an observer (mutating
        // the dict) synchronously, which would trap on the live collection.
        for callback in Array(paneOutputObservers.values) { callback(paneId, data) }
    }

    /// Fans a pane's working directory out to every cwd observer.
    func emitPaneCwd(_ paneId: Int, _ path: String) {
        for callback in Array(paneCwdObservers.values) { callback(paneId, path) }
    }

    /// Fans a pane's reflow classification out to every reflow observer.
    func emitPaneReflow(_ paneId: Int, _ noReflow: Bool) {
        for callback in Array(paneReflowObservers.values) { callback(paneId, noReflow) }
    }

    /// Fans a window's new active pane out to every active-pane observer.
    func emitActivePaneChanged(_ windowId: Int, _ paneId: Int) {
        for callback in Array(activePaneObservers.values) { callback(windowId, paneId) }
    }

    /// Notifies every observer that the remote session name changed.
    func emitSessionChanged(oldName: String, newName: String) {
        for callback in Array(sessionChangedObservers.values) { callback(oldName, newName) }
    }

    /// Notifies every topology observer that the window/pane layout changed.
    func notifyTopologyChanged() {
        for callback in Array(topologyObservers.values) { callback() }
    }

    /// Notifies every exit observer that the connection permanently ended.
    func notifyExit() {
        // Snapshot: notifyExit -> handleSessionEndedRemotely -> detachObserver ->
        // removeObserver mutates exitObservers synchronously during this loop.
        for callback in Array(exitObservers.values) { callback() }
    }

    /// Notifies every connection-state observer of a transition.
    func notifyStateChanged(_ state: RemoteTmuxControlConnection.ConnectionState) {
        for callback in Array(stateObservers.values) { callback(state) }
    }
}
