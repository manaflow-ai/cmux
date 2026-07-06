public import Foundation
internal import Observation

/// The main-actor RPC dispatch half of the former `TerminalController`: it
/// receives decoded ``ControlRequest``s, runs the command logic against live
/// app state strictly through the read-only ``ControlCommandContext`` seam, and
/// returns a typed ``ControlCallResult``. It does no socket I/O and never
/// imports the app target.
///
/// ## Isolation
///
/// `@MainActor` because its sole collaborator (``ControlCommandContext``) lives
/// on the main actor and the legacy command bodies always executed on main
/// (the socket worker hopped once via `v2MainSync { processCommand }`). Running
/// the coordinator on main turns every former per-read `v2MainSync` hop into a
/// plain in-isolation call, so moved domains shed their hops outright. Worker-
/// lane methods (`vm.*`, `system.top`, …) that block or await are NOT handled
/// here; they stay on the app-side worker path.
///
/// ## State ownership
///
/// The coordinator owns the ``ControlHandleRegistry`` — the `kind:N` ref mint
/// that the RPC layer uses to hand opaque handles to callers. This is RPC
/// selection state, so it belongs here (the plan's state split). The interim
/// composition owner (`TerminalController`) routes its own `ensureRef` /
/// `resolveRef` / `removeRef` through the coordinator so refs stay consistent
/// across moved and not-yet-moved domains.
@MainActor
@Observable
public final class ControlCommandCoordinator {
    /// The live app-state seam. Weak to avoid a retain cycle with the interim
    /// composition owner, which owns the coordinator and sets this to `self`
    /// during its own init. Not observation-tracked: it is wired once.
    @ObservationIgnored
    public weak var context: (any ControlCommandContext)?

    /// The shared `kind:N` handle registry. Single source of truth for ref
    /// minting across the RPC layer. Not observation-tracked: it is RPC
    /// book-keeping (a struct mutated by `ref()` on nearly every response),
    /// not UI state, and tracking it would invalidate any observer on every
    /// socket command.
    @ObservationIgnored
    public var handles: ControlHandleRegistry

    /// Creates a coordinator.
    ///
    /// - Parameters:
    ///   - context: The app-state seam. May be set after init (see ``context``).
    ///   - handles: The handle registry to adopt. Defaults to a fresh one.
    public init(
        context: (any ControlCommandContext)? = nil,
        handles: ControlHandleRegistry = ControlHandleRegistry()
    ) {
        self.context = context
        self.handles = handles
    }

    // MARK: - Dispatch

    /// Runs one decoded request if it belongs to a domain this coordinator
    /// owns, returning the typed result; returns `nil` for methods still served
    /// by the legacy app-side dispatcher so the caller can fall through.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not owned here.
    public func handle(_ request: ControlRequest) -> ControlCallResult? {
        // Each domain's handler (in its own `+<Domain>.swift` extension) owns its
        // methods and returns `nil` for anything else, so the chain falls through
        // to the next domain and finally to the legacy app-side dispatcher.
        if let result = handleWindow(request) { return result }
        if let result = handleAppFocus(request) { return result }
        if let result = handleFeed(request) { return result }
        if let result = handleNotification(request) { return result }
        if let result = handleWorkspaceGroup(request) { return result }
        if let result = handlePane(request) { return result }
        if let result = handleCanvas(request) { return result }
        if let result = handleMobileHost(request) { return result }
        if let result = handleWorkspace(request) { return result }
        if let result = handleSurface(request) { return result }
        if let result = handleSystem(request) { return result }
        if let result = handleProject(request) { return result }
        if let result = handleDebug(request) { return result }
        if let result = handleBrowser(request) { return result }
        if let result = handleBrowserReadOnly(request) { return result }
        if let result = handleBrowserConsoleErrorsState(request) { return result }
        if let result = handleBrowserTabs(request) { return result }
        if let result = handleBrowserUnsupported(request) { return result }
        // Only the non-JS-evaluating, main-actor browser.* methods are owned
        // here (handleBrowser / handleBrowserUnsupported). The JS-evaluating
        // browser.* methods stay
        // app-side: PR 5778 moved them onto the socket-worker lane (nonisolated
        // bodies + v2MainSync), which the @MainActor coordinator seam cannot
        // host; re-lift them against that architecture in a follow-up.
        // handleSidebarV1 / handleBrowserPanelV1 are V1 string-command handlers;
        // the app's v1 dispatcher calls them directly with (command:args:).
        return nil
    }

    /// Runs one decoded request on the calling socket-worker thread if it is
    /// a coordinator-owned worker-lane method (the tranche-D resolution
    /// reads and the tranche-E sends); returns `nil` otherwise so the
    /// app-side worker dispatch can fall through to its own cases (and
    /// finally to its loud policy-without-handler backstop).
    ///
    /// Each body is `nonisolated`: pure parse and the JSON payload build/
    /// encode run on the calling thread, and every main-actor touch —
    /// known-ref refresh, routing resolution through the handle registry,
    /// the context snapshot witness, and ref minting in payload order — is
    /// one `controlResolveOnMain` hop. The same bodies serve the main-actor
    /// `handle(_:)` dispatch, where the hop collapses inline, so both lanes
    /// run identical code.
    ///
    /// - Parameters:
    ///   - request: The decoded request envelope.
    ///   - context: The live app seam (the app's composition owner, passed
    ///     explicitly because the coordinator's `context` property is
    ///     main-actor-isolated).
    /// - Returns: The command result, or `nil` if not a coordinator-owned
    ///   worker-lane method.
    public nonisolated func handleSocketWorkerV2(
        _ request: ControlRequest,
        context: (any ControlCommandContext)?
    ) -> ControlCallResult? {
        switch request.method {
        case "surface.list":
            return surfaceList(request.params, context: context)
        case "surface.current":
            return surfaceCurrent(request.params, context: context)
        case "workspace.list":
            return workspaceList(request.params, context: context)
        case "workspace.current":
            return workspaceCurrent(request.params, context: context)
        case "window.list":
            return windowList(context: context)
        case "window.current":
            return windowCurrent(request.params, context: context)
        case "window.displays":
            return windowDisplays(context: context)
        case "pane.list":
            return paneList(request.params, context: context)
        case "pane.surfaces":
            return paneSurfaces(request.params, context: context)
        case "system.identify":
            return systemIdentify(request.params, context: context)
        case "system.tree":
            return systemTree(request.params, context: context)
        case "surface.send_text":
            return surfaceSendText(request.params, context: context)
        case "surface.send_key":
            return surfaceSendKey(request.params, context: context)
        default:
            return nil
        }
    }

    // MARK: - Handle registry (shared ref minting)

    /// Mints or returns the stable `kind:N` ref for an identifier.
    ///
    /// - Parameters:
    ///   - kind: The handle kind.
    ///   - uuid: The identifier to ref.
    /// - Returns: The ref string.
    @discardableResult
    public func ensureRef(kind: ControlHandleKind, uuid: UUID) -> String {
        handles.ensureRef(kind: kind, uuid: uuid)
    }

    /// Resolves a previously-minted `kind:N` ref back to its identifier.
    ///
    /// - Parameter ref: The ref string.
    /// - Returns: The identifier, or `nil` if unknown.
    public func resolveRef(_ ref: String) -> UUID? {
        handles.uuid(forRef: ref)
    }

    /// Drops the ref for an identifier (without reusing its ordinal).
    ///
    /// - Parameters:
    ///   - kind: The handle kind.
    ///   - uuid: The identifier to forget.
    public func removeRef(kind: ControlHandleKind, uuid: UUID) {
        handles.removeRef(kind: kind, uuid: uuid)
    }

    // MARK: - Ref aggregations

    /// The stable `kind:N` refs for a batch of workspace ids, minting any that
    /// do not yet exist (the legacy `v2WorkspaceRefs`).
    ///
    /// - Parameter ids: The workspace identifiers to ref.
    /// - Returns: A map from each id to its ref string.
    public func v2WorkspaceRefs(for ids: [UUID]) -> [UUID: String] {
        var refs: [UUID: String] = [:]
        refs.reserveCapacity(ids.count)
        for id in ids {
            refs[id] = ensureRef(kind: .workspace, uuid: id)
        }
        return refs
    }

    /// The workspace, optional pane, and surface refs for one location, minting
    /// each as needed (the legacy `v2WorkspacePaneAndSurfaceRefs`).
    ///
    /// - Parameters:
    ///   - workspaceId: The workspace identifier.
    ///   - paneId: The pane identifier, or `nil`.
    ///   - surfaceId: The surface identifier.
    /// - Returns: The minted refs.
    public func v2WorkspacePaneAndSurfaceRefs(
        workspaceId: UUID,
        paneId: UUID?,
        surfaceId: UUID
    ) -> (workspaceRef: String, paneRef: String?, surfaceRef: String) {
        return (
            workspaceRef: ensureRef(kind: .workspace, uuid: workspaceId),
            paneRef: paneId.map { ensureRef(kind: .pane, uuid: $0) },
            surfaceRef: ensureRef(kind: .surface, uuid: surfaceId)
        )
    }

    /// The `tab:N` ref for an optional surface id as a wire value: the surface
    /// ref re-prefixed `surface:` → `tab:`, or `NSNull` when absent (the legacy
    /// `v2TabRef`; returns `Any` because callers fold it into Foundation
    /// `[String: Any]` payloads).
    ///
    /// - Parameter uuid: The surface identifier, or `nil`.
    /// - Returns: The `tab:N` ref string, or `NSNull`.
    public func v2TabRef(uuid: UUID?) -> Any {
        guard let uuid else { return NSNull() }
        let surfaceRef = ensureRef(kind: .surface, uuid: uuid)
        return surfaceRef.replacingOccurrences(of: "surface:", with: "tab:")
    }

    // MARK: - Wire helpers

    /// The `kind:N` ref for an optional id as a JSON value: the ref string, or
    /// JSON `null` when the id is absent (the legacy `v2Ref` `NSNull` case).
    func ref(_ kind: ControlHandleKind, _ uuid: UUID?) -> JSONValue {
        guard let uuid else { return .null }
        return .string(handles.ensureRef(kind: kind, uuid: uuid))
    }

    /// A string as a JSON value, or JSON `null` when absent (the legacy
    /// `v2OrNull` `NSNull` case). `nonisolated`: pure value mapping, used by
    /// the worker-lane bodies' off-main payload shaping.
    nonisolated func orNull(_ value: String?) -> JSONValue {
        guard let value else { return .null }
        return .string(value)
    }

    // MARK: - Param parsing (typed twin of v2String / v2UUID / v2HasNonNullParam)

    /// A trimmed, non-empty string param, or `nil` (matches legacy `v2String`:
    /// only a JSON string counts; whitespace-only is treated as absent).
    ///
    /// Public so the app-resident `workspace.remote.configure` witness reads its
    /// params through this single coercion (the former app-side `jvString`).
    /// `nonisolated`: pure param read, used by the worker-lane bodies'
    /// off-main parse.
    public nonisolated func string(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let raw)? = params[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A UUID param, accepting either a UUID string or a `kind:N` ref resolved
    /// through the handle registry (matches legacy `v2UUID`).
    func uuid(_ params: [String: JSONValue], _ key: String) -> UUID? {
        guard let raw = string(params, key) else { return nil }
        if let parsed = UUID(uuidString: raw) {
            return parsed
        }
        return handles.uuid(forRef: raw)
    }

    /// Whether a param is present and not JSON `null` (matches legacy
    /// `v2HasNonNullParam`).
    ///
    /// Public so the app-resident `workspace.remote.configure` witness reuses this
    /// presence check (the former app-side `jvHasNonNullParam`).
    public func hasNonNull(_ params: [String: JSONValue], _ key: String) -> Bool {
        guard let value = params[key] else { return false }
        if case .null = value { return false }
        return true
    }

    /// Builds the routing selectors for `window.current`, resolving each
    /// selector through the handle registry exactly as the legacy
    /// `v2ResolveTabManager` did before walking its precedence.
    func routingSelectors(_ params: [String: JSONValue]) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: hasNonNull(params, "window_id"),
            windowID: uuid(params, "window_id"),
            groupID: uuid(params, "group_id"),
            workspaceID: uuid(params, "workspace_id"),
            surfaceID: uuid(params, "surface_id")
                ?? uuid(params, "terminal_id")
                ?? uuid(params, "tab_id"),
            paneID: uuid(params, "pane_id")
        )
    }
}
