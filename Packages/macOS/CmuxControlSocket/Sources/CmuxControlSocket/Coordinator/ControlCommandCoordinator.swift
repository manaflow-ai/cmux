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

    @ObservationIgnored
    nonisolated let simulatorOperationAdmissionGate =
        ControlSimulatorOperationAdmissionGate(maximumConcurrentOperations: 4)

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
        if let result = handleLayout(request) { return result }
        if let result = handleWorkspaceGroup(request) { return result }
        if let result = handleWorkspaceTodo(request) { return result }
        if let result = handlePane(request) { return result }
        if let result = handleCanvas(request) { return result }
        if let result = handleMobileHost(request) { return result }
        if let result = handleWorkspace(request) { return result }
        if let result = handleSurface(request) { return result }
        if let result = handleSystem(request) { return result }
        if let result = handleProject(request) { return result }
        if let result = handleDebug(request) { return result }
        // The v2 browser.* domain stays app-side: PR 5778 moved its
        // JS-evaluating methods onto the socket-worker lane (nonisolated
        // bodies + v2MainSync), which the @MainActor coordinator seam cannot
        // host; re-lift it against that architecture in a follow-up.
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
        case "workspace.remote.terminal_session_launching":
            return workspaceRemoteTerminalSessionLaunching(
                request.params,
                context: context
            )
        case "workspace.remote.terminal_session_connected":
            return workspaceRemoteTerminalSessionConnected(
                request.params,
                context: context
            )
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
        case "simulator.type":
            return simulatorType(request.params, context: context)
        case "simulator.web_inspector.targets",
             "simulator.web_inspector.attach",
             "simulator.web_inspector.send",
             "simulator.web_inspector.highlight",
             "simulator.web_inspector.release":
            return simulatorWebInspector(request, context: context)
        case "simulator.context", "simulator.prepare_screenshot",
             "simulator.select_device", "simulator.recover",
             "simulator.gesture", "simulator.multi_touch", "simulator.tap", "simulator.swipe",
             "simulator.button", "simulator.rotate", "simulator.core_animation",
             "simulator.memory_warning", "simulator.event_log", "simulator.tools",
             "simulator.camera.configure", "simulator.camera.switch",
             "simulator.camera.mirror", "simulator.camera.status",
             "simulator.permissions.read", "simulator.permissions.set",
             "simulator.ui.status", "simulator.ui.set",
             "simulator.accessibility", "simulator.foreground":
            return simulatorOperation(request, context: context)
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
    /// `nonisolated`: pure param read, used by the worker-lane bodies'
    /// off-main parse.
    nonisolated func string(_ params: [String: JSONValue], _ key: String) -> String? {
        guard case .string(let raw)? = params[key] else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A UUID param, accepting either a UUID string or a `kind:N` ref resolved
    /// through the handle registry (matches legacy `v2UUID`).
    ///
    /// An identifier only resolves when its kind is one the param key expects,
    /// so `group_id: "surface:1"` no longer resolves to a surface, misses its
    /// group lookup, and degrades to the active window
    /// (https://github.com/manaflow-ai/cmux/issues/9424).
    ///
    /// This holds for both wire representations. A `kind:N` ref names its kind
    /// outright. A raw UUID does not, but the registry knows the kinds it has
    /// already minted refs for, so a surface UUID supplied as `group_id` is
    /// rejected too. A UUID the registry has never seen has no known kind and
    /// still passes through — that is gap 1 of the issue, which needs a product
    /// call on distinguishing caller-injected context from user-specified
    /// targets on the wire.
    ///
    /// Keys with no declared expectation (`id`, notification/todo ids) keep the
    /// unrestricted lookup.
    func uuid(_ params: [String: JSONValue], _ key: String) -> UUID? {
        guard let raw = string(params, key) else { return nil }
        return resolveIdentifier(raw, forParamKey: key)
    }

    /// The routing-lane twin of ``uuid(_:_:)``: identical, except the Window
    /// Dock's window-as-`workspace_id` alias is accepted. Only the routing walk
    /// may take that alias, so it is never granted by param name alone.
    func routingUUID(_ params: [String: JSONValue], _ key: String) -> UUID? {
        guard let raw = string(params, key) else { return nil }
        return resolveIdentifier(raw, forParamKey: key, routing: true)
    }

    /// Resolves either wire representation of an identifier — a raw UUID string
    /// or a `kind:N` ref — for a named param key, rejecting kinds that key does
    /// not accept. The single entrypoint both the typed params and the legacy
    /// `[String: Any]` `v2UUID` path go through.
    ///
    /// - Parameters:
    ///   - raw: The trimmed, non-empty param value.
    ///   - key: The param key the value arrived under.
    ///   - routing: Whether this resolution feeds the routing walk, which is the
    ///     only caller allowed the window-as-`workspace_id` alias.
    /// - Returns: The identifier, or `nil` if unknown or of the wrong kind.
    public func resolveIdentifier(
        _ raw: String,
        forParamKey key: String,
        routing: Bool = false
    ) -> UUID? {
        guard let expected = acceptedKinds(forParamKey: key, routing: routing) else {
            // No declared expectation (`id`, notification/todo ids): unrestricted.
            return UUID(uuidString: raw) ?? handles.uuid(forRef: raw)
        }
        guard let parsed = UUID(uuidString: raw) else {
            return handles.uuid(forRef: raw, kinds: expected)
        }
        let known = identityKinds(for: parsed)
        // Empty means no source can name a kind for this identity, which is gap
        // 1 of the issue: the CLI injects the caller's own CMUX_WORKSPACE_ID /
        // CMUX_SURFACE_ID into most commands, so failing closed here would also
        // fail ordinary commands issued from a since-closed workspace. Telling
        // those apart needs the wire-format change the issue defers to a
        // product call.
        guard known.isEmpty || !known.isDisjoint(with: expected) else { return nil }
        return parsed
    }

    /// The kinds an identity is known to have, preferring the app's live
    /// topology over the handle registry's mint history.
    ///
    /// Mint history alone is not a sound oracle: dock-hosted objects may not be
    /// minted yet, and ``ControlHandleRegistry/removeRef(kind:uuid:)`` erases
    /// what the registry knew. The conformer answers from live topology when it
    /// can; the registry is the fallback for contexts with no app attached
    /// (tests, and any conformer that does not implement the seam).
    func identityKinds(for uuid: UUID) -> Set<ControlHandleKind> {
        if let authoritative = context?.controlIdentityKinds(for: uuid) {
            return authoritative
        }
        return handles.mintedKinds(for: uuid)
    }

    /// Resolves a `kind:N` ref for a named param key, restricted to the handle
    /// kinds that key accepts. Unknown keys keep the unrestricted search.
    ///
    /// - Parameters:
    ///   - ref: The ref string.
    ///   - key: The param key the ref arrived under.
    /// - Returns: The identifier, or `nil` if unknown or of the wrong kind.
    public func resolveRef(_ ref: String, forParamKey key: String) -> UUID? {
        guard let kinds = Self.expectedHandleKinds[key] else {
            return handles.uuid(forRef: ref)
        }
        return handles.uuid(forRef: ref, kinds: kinds)
    }

    /// The kinds a param key accepts, widened only for the routing lane.
    ///
    /// - Parameters:
    ///   - key: The param key.
    ///   - routing: Whether the resolution feeds the routing walk.
    /// - Returns: The accepted kinds, or `nil` when the key declares none.
    func acceptedKinds(forParamKey key: String, routing: Bool) -> [ControlHandleKind]? {
        if routing, let widened = Self.routingHandleKinds[key] { return widened }
        return Self.expectedHandleKinds[key]
    }

    /// The extra kinds the routing walk alone accepts.
    ///
    /// The Window Dock legitimately routes by passing a *window* identity as
    /// `workspace_id`, because a Dock owner id IS its owning window's id. That
    /// is a property of the routing walk, not of the parameter: a command that
    /// uses `workspace_id` as an actual workspace target must still reject a
    /// window, so the alias is granted per call site rather than by name.
    static let routingHandleKinds: [String: [ControlHandleKind]] = [
        "workspace_id": [.workspace, .window],
    ]

    /// The handle kinds each routing/target param key accepts.
    ///
    /// `tab:N` for surfaces is the one alias handled inside the registry. The
    /// window-as-`workspace_id` alias is NOT here: see ``routingHandleKinds``.
    ///
    /// `from_tab_id`/`to_tab_id` are workspaces despite the name: they are
    /// matched against a window's workspace list, not against surfaces.
    static let expectedHandleKinds: [String: [ControlHandleKind]] = [
        "window_id": [.window],
        "workspace_id": [.workspace],
        "reference_workspace_id": [.workspace],
        "group_reference_workspace_id": [.workspace],
        "before_workspace_id": [.workspace],
        "after_workspace_id": [.workspace],
        "_cmux_remote_workspace_id": [.workspace],
        "from_tab_id": [.workspace],
        "to_tab_id": [.workspace],
        "group_id": [.workspaceGroup],
        "before_group_id": [.workspaceGroup],
        "after_group_id": [.workspaceGroup],
        "pane_id": [.pane],
        "target_pane_id": [.pane],
        "surface_id": [.surface],
        "target_surface_id": [.surface],
        "before_surface_id": [.surface],
        "after_surface_id": [.surface],
        "terminal_id": [.surface],
        "tab_id": [.surface],
        "panel_id": [.surface],
        "return_to": [.surface],
    ]

    /// Whether a param is present and not JSON `null` (matches legacy
    /// `v2HasNonNullParam`).
    func hasNonNull(_ params: [String: JSONValue], _ key: String) -> Bool {
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
            windowID: routingUUID(params, "window_id"),
            groupID: routingUUID(params, "group_id"),
            workspaceID: routingUUID(params, "workspace_id"),
            surfaceID: routingUUID(params, "surface_id")
                ?? routingUUID(params, "terminal_id")
                ?? routingUUID(params, "tab_id"),
            paneID: routingUUID(params, "pane_id")
        )
    }
}
