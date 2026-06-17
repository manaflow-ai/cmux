/// The mobile-host-domain slice of the control-command seam (a constituent of
/// the ``ControlCommandContext`` umbrella).
///
/// This domain serves the `mobile.*` / `terminal.*` methods the Mac exposes to
/// the paired iOS client through the v2 control socket: host status, the
/// mobile-shaped workspace/terminal list, terminal create, and the terminal
/// input / replay / viewport / scroll / mouse data-plane verbs.
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
/// ## Two entrypoints, one seam
///
/// Both the v2 control socket (`processV2Command`, sync, main-actor) and the
/// mobile data-plane RPC handler (`mobileHostHandleRPC`, async) dispatch the
/// mobile-host domain. The coordinator owns the dispatch table for both:
/// ``ControlCommandCoordinator/handleMobileHost(_:)`` answers the verbs reachable
/// from `processV2Command` (the eight shared verbs plus `mobile.terminal.paste` /
/// `terminal.paste` and the local debug `chat.sessions.dump`), and
/// ``ControlCommandCoordinator/handleMobileHostRPC(_:)`` answers the full RPC
/// surface (every verb above plus the attach-ticket / paste-image / workspace
/// create-action-close-group / chat / notification-sync / dogfood-feedback verbs
/// the phone reaches only through the data plane). Every method is a thin
/// pass-through to a seam method below; the app conformance runs the EXACT legacy
/// body and bridges its Foundation payload to a ``JSONValue``.
///
/// The methods that block or await on app state are `async` here (attach-ticket
/// mint, chat history, dogfood-feedback persistence); the rest are synchronous,
/// matching the legacy bodies exactly.
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

    /// `mobile.host.status` (mobile data-plane RPC) — the public-status variant
    /// the phone receives over the RPC handler, omitting private metadata
    /// (`includePrivateMetadata: false`), matching the legacy
    /// `mobileHostHandleRPC` argument.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileHostStatusPublic(params: [String: JSONValue]) -> ControlCallResult

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

    /// `mobile.attach_ticket.create` — mint a short-lived attach ticket for the
    /// paired phone. Awaits the socket worker, so it is `async`.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileAttachTicketCreate(params: [String: JSONValue]) async -> ControlCallResult

    /// `mobile.terminal.paste_image` / `terminal.paste_image` — paste a decoded
    /// image into the resolved terminal surface.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileTerminalPasteImage(params: [String: JSONValue]) -> ControlCallResult

    /// `workspace.create` — create a workspace from the mobile data plane.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileWorkspaceCreate(params: [String: JSONValue]) -> ControlCallResult

    /// `workspace.action` — the mobile-gated workspace action wrapper
    /// (pin/unpin/rename/mark-read).
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileWorkspaceAction(params: [String: JSONValue]) -> ControlCallResult

    /// `mobile.chat.*` — the iOS agent-chat verbs (sessions / history / send /
    /// interrupt / answer). Awaits transcript I/O, so it is `async`.
    ///
    /// - Parameters:
    ///   - method: The full `mobile.chat.*` method name.
    ///   - params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileChatDispatch(method: String, params: [String: JSONValue]) async -> ControlCallResult

    /// `workspace.close` — close a workspace from the mobile data plane.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileWorkspaceClose(params: [String: JSONValue]) -> ControlCallResult

    /// `workspace.group.collapse` / `workspace.group.expand` — set a workspace
    /// group's collapsed state from the mobile data plane.
    ///
    /// - Parameters:
    ///   - params: The decoded request params.
    ///   - isCollapsed: `true` for collapse, `false` for expand.
    /// - Returns: The fully-built command result.
    func controlMobileWorkspaceGroupSetCollapsed(
        params: [String: JSONValue],
        isCollapsed: Bool
    ) -> ControlCallResult

    /// `notification.dismiss` (mobile data plane) — mark notifications read on the
    /// Mac in response to a phone-side banner dismiss (cross-device dismiss-sync).
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileNotificationDismiss(params: [String: JSONValue]) -> ControlCallResult

    /// `notification.reconcile` (mobile data plane) — the foreground reconcile
    /// sweep reporting which phone-delivered banners this Mac handled.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileNotificationReconcile(params: [String: JSONValue]) -> ControlCallResult

    /// `dogfood.feedback.submit` — the privileged agent-feedback sink. Persists a
    /// bundle off the main actor, so it is `async`.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully-built command result.
    func controlMobileDogfoodFeedbackSubmit(params: [String: JSONValue]) async -> ControlCallResult
}
