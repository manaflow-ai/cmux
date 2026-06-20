import CmuxControlSocket
import CmuxRemoteSession
import Foundation

/// App-side wiring for the worker-lane `workspace.remote.pty_*` control commands.
///
/// The command bodies live in CmuxControlSocket's ``ControlRemotePTYWorker``;
/// this file supplies the live-state seam (``ControlRemotePTYReading``) the
/// worker resolves targets through, the per-target controller seam
/// (``ControlRemotePTYControlling``) over the live `RemoteSessionCoordinator`,
/// and the one worker-thread→async bridge that lets the synchronous `nonisolated`
/// socket-worker lane drive the worker.
///
/// ## Why the seam, not a direct call
///
/// `ControlRemotePTYWorker` is in a package that must not import the app target,
/// where the `workspace.remote.pty_*` commands resolve their target by reading
/// the live window/workspace/surface graph (`AppDelegate.shared`, each
/// `Workspace`'s remote controller and moved-surface matching, the `TabManager`
/// ownership graph, the handle-ref vocabulary, and the workspace/surface UUID
/// coercion). ``ControlRemotePTYReading`` inverts that: the package owns the
/// protocol and the command bodies, ``TerminalControllerRemotePTYReading``
/// conforms it by forwarding to the `@MainActor`-coupled resolution methods that
/// stay on ``TerminalController`` (they reach `v2MainSync` / `v2Ref` / `v2UUID`
/// and the availability `NSCondition`), and the resolved controller is bound
/// behind ``ControlRemotePTYControlling`` so the worker drives it without the
/// `RemoteSessionCoordinator` type.
extension TerminalController {
    /// Drives the package ``ControlRemotePTYWorker`` for one decoded
    /// `workspace.remote.pty_*` request from the synchronous socket-worker lane.
    /// The worker is itself synchronous (its controller calls block the worker
    /// thread on the controller queue exactly as the legacy bodies did), so this
    /// is a direct call, not a semaphore bridge. The worker only returns `nil`
    /// for non-`workspace.remote.pty_*` methods, which the dispatcher never routes
    /// here, so a `nil` result reports the same encode-failure response the legacy
    /// plumbing produced for an impossible payload.
    nonisolated func runRemotePTYWorker(_ request: ControlRequest) -> String {
        guard let result = controlRemotePTYWorker?.handle(request) else {
            return ControlResponseEncoder.encodeFailureResponse
        }
        return Self.v2Encoder.response(id: request.id, result)
    }

    // MARK: - Resolution seam (the former v2RequestedRemotePTY* / v2ResolveRemotePTYTarget*)

    /// Resolves the requested `workspace_id` to a UUID (the former
    /// `v2RequestedRemotePTYWorkspaceID`). Stays app-side: `v2UUID` resolves a
    /// handle ref on the main actor.
    nonisolated func ptyRequestedWorkspaceID(
        params: [String: Any]
    ) -> (workspaceID: UUID?, error: ControlCallResult?) {
        var workspaceId: UUID?
        var invalidWorkspaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            workspaceId = v2UUID(params, "workspace_id")
            invalidWorkspaceID = v2HasNonNullParam(params, "workspace_id") && workspaceId == nil
        }
        if invalidWorkspaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid workspace_id", data: nil)
            )
        }
        return (workspaceId, nil)
    }

    /// Resolves the requested `surface_id` to a UUID (the former
    /// `v2RequestedRemotePTYSurfaceID`).
    nonisolated func ptyRequestedSurfaceID(
        params: [String: Any]
    ) -> (surfaceID: UUID?, error: ControlCallResult?) {
        var surfaceId: UUID?
        var invalidSurfaceID = false
        v2MainSync {
            v2RefreshKnownRefs()
            surfaceId = v2UUID(params, "surface_id")
            invalidSurfaceID = v2HasNonNullParam(params, "surface_id") && surfaceId == nil
        }
        if invalidSurfaceID {
            return (
                nil,
                .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
            )
        }
        return (surfaceId, nil)
    }

    /// Resolves the target workspace's controller + refs (the former
    /// `v2ResolveRemotePTYTarget`), returning the Sendable package twin.
    nonisolated func ptyResolveTarget(
        params: [String: Any],
        requestedWorkspaceId: UUID?,
        preferredSurfaceId: UUID? = nil
    ) -> ControlRemotePTYTargetResolution {
        if v2HasNonNullParam(params, "allow_moved_surface"),
           v2Bool(params, "allow_moved_surface") == nil {
            return ControlRemotePTYTargetResolution(
                target: nil,
                error: .err(code: "invalid_params", message: "Missing or invalid allow_moved_surface", data: nil)
            )
        }
        let allowMovedSurface = v2Bool(params, "allow_moved_surface") ?? false
        let requestedSessionID = v2RawString(params, "session_id").flatMap { raw -> String? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var resolvedWorkspaceId: UUID?
        var target: ControlRemotePTYTarget?
        var workspaceMismatchData: JSONValue?

        v2MainSync {
            v2RefreshKnownRefs()
            let fallbackTabManager = v2ResolveTabManager(params: params)
            let fallbackWorkspaceId = requestedWorkspaceId ?? fallbackTabManager?.selectedTabId
            var owner: TabManager?
            var workspace: Workspace?
            if let preferredSurfaceId {
                if let fallbackTabManager,
                   let surfaceWorkspace = fallbackTabManager.tabs.first(where: {
                       $0.panels[preferredSurfaceId] != nil
                           && $0.surfaceIdFromPanelId(preferredSurfaceId) != nil
                   }) {
                    owner = fallbackTabManager
                    workspace = surfaceWorkspace
                } else if let located = AppDelegate.shared?.workspaceContainingPanel(
                    panelId: preferredSurfaceId,
                    preferredWorkspaceId: fallbackWorkspaceId
                ) {
                    owner = located.tabManager
                    workspace = located.workspace
                }
            }
            if workspace == nil,
               let fallbackWorkspaceId,
               let fallbackOwner = AppDelegate.shared?.tabManagerFor(tabId: fallbackWorkspaceId),
               let fallbackWorkspace = fallbackOwner.tabs.first(where: { $0.id == fallbackWorkspaceId }) {
                owner = fallbackOwner
                workspace = fallbackWorkspace
            }
            resolvedWorkspaceId = workspace?.id ?? fallbackWorkspaceId
            guard let owner, let workspace else {
                return
            }
            if let requestedWorkspaceId,
               workspace.id != requestedWorkspaceId {
                let matchedMovedSurface = allowMovedSurface
                    && preferredSurfaceId.map {
                        workspace.remotePTYSessionIDMatches(panelId: $0, sessionID: requestedSessionID)
                    } == true
                guard matchedMovedSurface else {
                    workspaceMismatchData = .object([
                        "workspace_id": .string(requestedWorkspaceId.uuidString),
                        "workspace_ref": Self.ptyRefValue(v2Ref(kind: .workspace, uuid: requestedWorkspaceId)),
                        "surface_id": preferredSurfaceId.map { JSONValue.string($0.uuidString) } ?? .null,
                        "surface_ref": Self.ptyRefValue(v2Ref(kind: .surface, uuid: preferredSurfaceId)),
                        "resolved_workspace_id": .string(workspace.id.uuidString),
                        "resolved_workspace_ref": Self.ptyRefValue(v2Ref(kind: .workspace, uuid: workspace.id)),
                    ])
                    return
                }
            }

            let windowId = v2ResolveWindowId(tabManager: owner)
            target = ControlRemotePTYTarget(
                controller: workspace.remotePTYSessionControllerForSocketCommand()
                    .map { RemoteSessionCoordinatorPTYControlling(controller: $0) },
                windowID: windowId,
                windowRef: Self.ptyRefValue(v2Ref(kind: .window, uuid: windowId)),
                workspaceID: workspace.id,
                workspaceRef: Self.ptyRefValue(v2Ref(kind: .workspace, uuid: workspace.id)),
                workspaceTitle: workspace.title
            )
        }

        if let workspaceMismatchData {
            return ControlRemotePTYTargetResolution(
                target: nil,
                error: .err(
                    code: "invalid_params",
                    message: "surface_id does not belong to workspace_id",
                    data: workspaceMismatchData
                )
            )
        }
        guard let resolvedWorkspaceId else {
            return ControlRemotePTYTargetResolution(
                target: nil,
                error: .err(code: "invalid_params", message: "Missing workspace_id", data: nil)
            )
        }
        guard let target else {
            return ControlRemotePTYTargetResolution(
                target: nil,
                error: .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: ptyWorkspaceData(workspaceId: resolvedWorkspaceId)
                )
            )
        }
        return ControlRemotePTYTargetResolution(target: target, error: nil)
    }

    /// Bumps the controller-availability generation and wakes every
    /// `pty_bridge` waiter (the former `notifyRemotePTYControllerAvailabilityChanged`).
    /// Called from the workspace remote-connection lifecycle (`Workspace`, the
    /// workspace-domain conformance) when a remote controller attaches/detaches.
    nonisolated func notifyRemotePTYControllerAvailabilityChanged() {
        remotePTYControllerAvailabilityCondition.lock()
        remotePTYControllerAvailabilityGeneration &+= 1
        remotePTYControllerAvailabilityCondition.broadcast()
        remotePTYControllerAvailabilityCondition.unlock()
    }

    /// Resolves the target, blocking on the availability `NSCondition` until the
    /// controller appears or `deadline` passes (the former
    /// `v2ResolveRemotePTYTargetWaitingForController`).
    nonisolated func ptyResolveTargetWaitingForController(
        params: [String: Any],
        requestedWorkspaceId: UUID?,
        preferredSurfaceId: UUID?,
        deadline: Date
    ) -> ControlRemotePTYTargetResolution {
        var observedGeneration: UInt64?

        while true {
            let resolved = ptyResolveTarget(
                params: params,
                requestedWorkspaceId: requestedWorkspaceId,
                preferredSurfaceId: preferredSurfaceId
            )
            if let error = resolved.error {
                return ControlRemotePTYTargetResolution(target: nil, error: error)
            }
            guard let target = resolved.target else {
                return resolved
            }
            if target.controller != nil || Date() >= deadline {
                return ControlRemotePTYTargetResolution(target: target, error: nil)
            }

            remotePTYControllerAvailabilityCondition.lock()
            let currentGeneration = remotePTYControllerAvailabilityGeneration
            guard let previousGeneration = observedGeneration else {
                observedGeneration = currentGeneration
                remotePTYControllerAvailabilityCondition.unlock()
                continue
            }
            if previousGeneration != currentGeneration {
                observedGeneration = currentGeneration
                remotePTYControllerAvailabilityCondition.unlock()
                continue
            }
            _ = remotePTYControllerAvailabilityCondition.wait(until: deadline)
            observedGeneration = remotePTYControllerAvailabilityGeneration
            remotePTYControllerAvailabilityCondition.unlock()
        }
    }

    /// Enumerates every remote workspace across every window (the former
    /// `all_workspaces` branch of `v2WorkspaceRemotePTYSessions`).
    nonisolated func ptyAllWorkspaceTargets() -> [ControlRemotePTYTarget] {
        var targets: [ControlRemotePTYTarget] = []
        v2MainSync {
            v2RefreshKnownRefs()
            guard let app = AppDelegate.shared else { return }
            for summary in app.listMainWindowSummaries() {
                guard let owner = app.tabManagerFor(windowId: summary.windowId) else { continue }
                for workspace in owner.tabs where workspace.isRemoteWorkspace {
                    targets.append(
                        ControlRemotePTYTarget(
                            controller: workspace.remotePTYSessionControllerForSocketCommand()
                                .map { RemoteSessionCoordinatorPTYControlling(controller: $0) },
                            windowID: summary.windowId,
                            windowRef: Self.ptyRefValue(v2Ref(kind: .window, uuid: summary.windowId)),
                            workspaceID: workspace.id,
                            workspaceRef: Self.ptyRefValue(v2Ref(kind: .workspace, uuid: workspace.id)),
                            workspaceTitle: workspace.title
                        )
                    )
                }
            }
        }
        return targets
    }

    /// Builds the `not_found` data payload for a resolved-but-missing workspace
    /// (the former `v2RemotePTYWorkspaceData`).
    private nonisolated func ptyWorkspaceData(workspaceId: UUID) -> JSONValue {
        var workspaceRef = JSONValue.null
        v2MainSync {
            workspaceRef = Self.ptyRefValue(v2Ref(kind: .workspace, uuid: workspaceId))
        }
        return .object([
            "workspace_id": .string(workspaceId.uuidString),
            "workspace_ref": workspaceRef,
        ])
    }

    /// Encodes a legacy `v2Ref` result (an `NSNull` or a handle-ref `String`) as
    /// a ``JSONValue`` for the package target, falling back to `.null` for an
    /// unencodable value (unreachable for the ref vocabulary).
    private nonisolated static func ptyRefValue(_ ref: Any) -> JSONValue {
        JSONValue(foundationObject: ref) ?? .null
    }
}

/// Conforms ``ControlRemotePTYReading`` over a `weak` ``TerminalController``.
///
/// `@unchecked Sendable` (not `@MainActor`): the resolution must run on the
/// socket-worker thread, matching the legacy `nonisolated` `v2ResolveRemotePTY*`
/// bodies (which hopped to main internally with `v2MainSync`). The only stored
/// member is a `weak` reference to the app-lifetime ``TerminalController``
/// singleton; the controller's resolution methods are `nonisolated` and perform
/// their own `v2MainSync` hops (and the availability `NSCondition` wait), so no
/// isolation is required on the conformer. The `weak` reference is read on the
/// worker thread, which is safe for a singleton whose lifetime spans every
/// connection. A `nil` `owner` (only reachable after teardown) reproduces the
/// legacy "Workspace not found" / no-targets head.
final class TerminalControllerRemotePTYReading: ControlRemotePTYReading, @unchecked Sendable {
    private weak var owner: TerminalController?

    /// Creates the conformer.
    /// - Parameter owner: The controller whose live graph + availability
    ///   condition back the seam.
    init(owner: TerminalController) {
        self.owner = owner
    }

    func requestedWorkspaceID(
        params: [String: JSONValue]
    ) -> (workspaceID: UUID?, error: ControlCallResult?) {
        guard let owner else { return (nil, nil) }
        return owner.ptyRequestedWorkspaceID(params: Self.foundationParams(params))
    }

    func requestedSurfaceID(
        params: [String: JSONValue]
    ) -> (surfaceID: UUID?, error: ControlCallResult?) {
        guard let owner else { return (nil, nil) }
        return owner.ptyRequestedSurfaceID(params: Self.foundationParams(params))
    }

    func resolveTarget(
        params: [String: JSONValue],
        requestedWorkspaceID: UUID?,
        preferredSurfaceID: UUID?
    ) -> ControlRemotePTYTargetResolution {
        guard let owner else {
            return ControlRemotePTYTargetResolution(target: nil, error: nil)
        }
        return owner.ptyResolveTarget(
            params: Self.foundationParams(params),
            requestedWorkspaceId: requestedWorkspaceID,
            preferredSurfaceId: preferredSurfaceID
        )
    }

    func resolveTargetWaitingForController(
        params: [String: JSONValue],
        requestedWorkspaceID: UUID?,
        preferredSurfaceID: UUID?,
        deadlineUnixSeconds: Double
    ) -> ControlRemotePTYTargetResolution {
        guard let owner else {
            return ControlRemotePTYTargetResolution(target: nil, error: nil)
        }
        return owner.ptyResolveTargetWaitingForController(
            params: Self.foundationParams(params),
            requestedWorkspaceId: requestedWorkspaceID,
            preferredSurfaceId: preferredSurfaceID,
            deadline: Date(timeIntervalSince1970: deadlineUnixSeconds)
        )
    }

    func allWorkspaceTargets() -> [ControlRemotePTYTarget] {
        owner?.ptyAllWorkspaceTargets() ?? []
    }

    /// Bridges the typed `[String: JSONValue]` params back to the Foundation
    /// `[String: Any]` shape the legacy resolution helpers parse, matching the
    /// dispatcher's own `request.params.mapValues { $0.foundationObject }`.
    private static func foundationParams(_ params: [String: JSONValue]) -> [String: Any] {
        params.mapValues { $0.foundationObject }
    }
}

/// Binds one live `RemoteSessionCoordinator` behind ``ControlRemotePTYControlling``
/// so ``ControlRemotePTYWorker`` drives its five synchronous persistent-PTY
/// operations without the `RemoteSessionCoordinator` type. The session
/// dictionaries are bridged to ``JSONValue`` here (the package never sees the
/// daemon's `[String: Any]` wire shape).
///
/// `RemoteSessionCoordinator` is a `Sendable` CmuxRemoteSession reference whose
/// PTY methods block the calling thread on the controller queue (the legacy sync
/// contract), so this wrapper is a plain `Sendable` value.
struct RemoteSessionCoordinatorPTYControlling: ControlRemotePTYControlling {
    /// The live remote-session controller for the resolved workspace.
    let controller: RemoteSessionCoordinator

    func listPTYSessions() throws -> [JSONValue] {
        try controller.listPTYSessions().map { JSONValue(foundationObject: $0) ?? .object([:]) }
    }

    func closePTYSession(sessionID: String) throws {
        try controller.closePTYSession(sessionID: sessionID)
    }

    func detachPTYSession(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String
    ) throws {
        try controller.detachPTYSession(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken
        )
    }

    func startPTYBridge(
        sessionID: String,
        attachmentID: String,
        command: String?,
        requireExisting: Bool,
        waitForReady: Bool,
        timeout: Double
    ) throws -> ControlRemotePTYBridgeEndpoint {
        let endpoint = try controller.startPTYBridge(
            sessionID: sessionID,
            attachmentID: attachmentID,
            command: command,
            requireExisting: requireExisting,
            waitForReady: waitForReady,
            timeout: timeout
        )
        return ControlRemotePTYBridgeEndpoint(
            host: endpoint.host,
            port: endpoint.port,
            token: endpoint.token,
            sessionID: endpoint.sessionID,
            attachmentID: endpoint.attachmentID
        )
    }

    func resizePTY(
        sessionID: String,
        attachmentID: String,
        attachmentToken: String,
        cols: Int,
        rows: Int
    ) throws {
        try controller.resizePTY(
            sessionID: sessionID,
            attachmentID: attachmentID,
            attachmentToken: attachmentToken,
            cols: cols,
            rows: rows
        )
    }
}
