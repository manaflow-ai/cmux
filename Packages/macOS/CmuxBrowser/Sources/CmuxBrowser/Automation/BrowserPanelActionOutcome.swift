public import CmuxControlSocket

/// The outcome of a `press` / `keydown` / `keyup` / `scroll` browser panel
/// interaction, produced by ``BrowserAutomationController/resolveKeyEvent(params:script:host:)``
/// and ``BrowserAutomationController/resolveScroll(params:dx:dy:host:)`` and shaped
/// app-side into a `ControlBrowserInteractionResolution`.
///
/// The split is byte-faithful to the legacy bodies: a success carries only the
/// resolved workspace/surface identity plus the optional `--snapshot-after` walk
/// (the worker shapes the wire payload from it), while every failure branch (the
/// panel-resolution head, the `js_error` branch, the ref-not-found echo, and the
/// scroll not-found diagnostics) carries an already-built ``BrowserCommandResult``
/// the app bridges verbatim.
///
/// Intentionally **not** `Sendable`: ``failure(_:)`` wraps ``BrowserCommandResult``,
/// whose `Any` payload is the same untyped Foundation value the legacy worker lane
/// threaded synchronously. The value never crosses an async boundary; it is built
/// and consumed on the calling socket-worker thread.
public enum BrowserPanelActionOutcome {
    /// The interaction succeeded; the worker shapes the wire payload from the
    /// resolved identity plus the merged post-action snapshot.
    case success(ControlBrowserPanelActionSuccess)

    /// The interaction failed (or resolved a not-found diagnostic); the carried
    /// result is the already-shaped wire payload, bridged app-side verbatim.
    case failure(BrowserCommandResult)
}
