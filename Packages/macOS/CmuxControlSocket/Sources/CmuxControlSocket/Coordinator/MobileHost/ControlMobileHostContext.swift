/// The mobile-host-domain slice of the control-command seam (a constituent of
/// the ``ControlCommandContext`` umbrella).
///
/// This domain serves the `mobile.*` / `terminal.*` methods the Mac exposes to
/// the paired iOS client through the v2 control socket: host status, the
/// mobile-shaped workspace/terminal list, terminal create/close, and the
/// terminal input / replay / viewport / scroll / mouse data-plane verbs.
///
/// Unlike the window domain, these bodies build deeply nested,
/// app-state-derived payloads (render grids, per-workspace terminal lists,
/// viewport state-machine mutations) and resolve their target through the
/// legacy `v2ResolveTabManager` / `v2ResolveWorkspace` precedence. Re-modeling
/// every leaf as a typed snapshot would be a large, error-prone surface for a
/// faithful lift, and none of these payloads mint `kind:N` refs (every id is a
/// raw `uuidString`). So each seam method takes the coordinator's already-typed
/// params and returns a fully-built ``ControlCallResult``: the app conformance
/// runs the EXACT legacy body against live `AppDelegate` / `TabManager` /
/// `Workspace` / `MobileHostService` state and bridges its Foundation payload to
/// a ``JSONValue`` (lossless via `JSONValue(foundationObject:)`), so the encoded
/// wire bytes match byte-for-byte.
///
/// Building the result app-side also keeps the localized error strings
/// (`socket.terminal.processExited`, `socket.terminal.inputQueueFull`,
/// `socket.terminal.surfaceUnavailable`) resolving against the app bundle — if
/// the coordinator built them with `String(localized:)` they would bind to the
/// package bundle, which lacks those keys, and silently drop the non-English
/// translations (a wire change).
///
/// Every method is `@MainActor` because its conformer and the coordinator both
/// live on the main actor, so these are plain in-isolation calls — the per-read
/// `v2MainSync` hops the legacy command bodies used disappear once the domain
/// moves onto the coordinator.
///
/// ## One entrypoint: the v2 control socket
///
/// This seam serves only the v2 control socket (`processV2Command`, sync,
/// main-actor), dispatched by ``ControlCommandCoordinator/handleMobileHost(_:)``:
/// the shared verbs plus `mobile.terminal.paste` / `terminal.paste` and the local
/// debug `chat.sessions.dump`. Every method is a thin pass-through; the app
/// conformance runs the EXACT legacy body and bridges its Foundation payload to a
/// ``JSONValue``.
///
/// The mobile data-plane RPC (`TerminalController.mobileHostHandleRPC`) does NOT
/// transit this seam. It speaks `MobileHostRPCRequest` / `MobileHostRPCResult`
/// and dispatches its `v2Mobile*` bodies directly app-side, so routing it through
/// this coordinator (native `ControlCallResult`) would only add a pointless
/// `MobileHostRPCRequest → ControlRequest → ControlCallResult → MobileHostRPCResult`
/// type round-trip. The shared bodies keep both paths byte-identical without a
/// bridge.
@MainActor
public protocol ControlMobileHostContext: AnyObject {
    /// `mobile.host.status` (v2 control socket) — host identity, route status,
    /// advertised capabilities, and the resolved workspace count. The
    /// `processV2Command` path includes private metadata, matching the legacy
    /// default argument (`includePrivateMetadata: true`).
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileHostStatus(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.workspace.list` — the iOS-facing workspace/terminal list, scoped
    /// to a single window when a target selector is present and flattened across
    /// every main window otherwise.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileWorkspaceList(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.create` / `terminal.create` — create a terminal surface
    /// in the resolved workspace, then echo the mobile workspace list with the
    /// new terminal id.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalCreate(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.close` / `terminal.close` — close a terminal surface in
    /// the resolved workspace.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalClose(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.input` / `terminal.input` — forward typed text to the
    /// resolved terminal surface, applying any piggybacked viewport report.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalInput(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.replay` / `terminal.replay` — the cold-attach replay
    /// anchor (render-grid frame or VT/byte snapshot) for the resolved surface.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalReplay(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.viewport` / `terminal.viewport` — record or clear a
    /// device's reported grid, recompute the shared minimum, cap the surface,
    /// and echo the effective grid.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalViewport(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.scroll` / `terminal.scroll` — forward a phone scroll
    /// gesture to the resolved surface.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalScroll(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.mouse` / `terminal.mouse` — forward a phone tap to the
    /// resolved surface as a click at the given cell.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalMouse(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.terminal.paste` / `terminal.paste` — paste text into the resolved
    /// terminal surface as a bracketed paste.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalPaste(params: [String: JSONValue]) -> ControlCallResult

    /// `chat.sessions.dump` (local debug socket) — the full chat-session registry
    /// dump, for diagnosing inconsistent phone-side chat state.
    ///
    /// - Returns: The fully-built command result.
    func controlMobileChatSessionsDump() -> ControlCallResult
}
