internal import Foundation

/// `surface.move` — move a surface into a target window/workspace/pane, lifted
/// byte-faithfully from the former `TerminalController.v2SurfaceMove`.
///
/// The coordinator owns the orchestration: the `surface_id` and at-most-one-anchor
/// gates, the pure ``ControlSurfaceMovePlan`` routing precedence, the
/// ``ControlSurfaceMoveResolution`` same/cross-workspace branch, and the success
/// payload assembly (minting `window`/`workspace`/`pane`/`surface` `_ref` through
/// the shared handle registry). Every live `AppDelegate` / `Workspace` / Bonsplit
/// lookup and mutation stays app-side behind the extended
/// ``ControlSurfaceContext`` move witnesses, which return only Sendable snapshots
/// and resolution enums.
///
/// Dispatched by `handleSurface` for `surface.move`; the `pane.join` witness
/// forwards its resolved move to this same public entry (the legacy `pane.join`
/// delegated to `v2SurfaceMove`), so both surfaces share one move path.
extension ControlCommandCoordinator {
    /// Runs one `surface.move` request end to end.
    ///
    /// - Parameter params: The decoded request params.
    /// - Returns: The fully shaped call result.
    public func surfaceMove(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let surfaceID = uuid(params, "surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }

        // The pure param-decision layer (anchor-count validation, target-routing
        // precedence, destination index, same/cross branch) lives in
        // ``ControlSurfaceMovePlan`` / ``ControlSurfaceMoveResolution``; the live
        // window/workspace/pane lookups and Bonsplit mutations stay app-side
        // behind the move witnesses.
        let plan = ControlSurfaceMovePlan(
            surfaceID: surfaceID,
            requestedPaneID: uuid(params, "pane_id"),
            requestedWorkspaceID: uuid(params, "workspace_id"),
            requestedWindowID: uuid(params, "window_id"),
            beforeSurfaceID: uuid(params, "before_surface_id"),
            afterSurfaceID: uuid(params, "after_surface_id"),
            explicitIndex: int(params, "index")
        )

        if plan.anchorCountExceeded {
            return .err(
                code: "invalid_params",
                message: "Specify at most one of before_surface_id or after_surface_id",
                data: nil
            )
        }

        let requestedFocus = bool(params, "focus") ?? false

        guard let context else {
            return .err(code: "internal_error", message: "Failed to move surface", data: nil)
        }

        let source: ControlSurfaceMoveSourceSnapshot
        switch context.controlSurfaceMoveLocateSource(surfaceID: surfaceID) {
        case .appUnavailable:
            return .err(code: "unavailable", message: "AppDelegate not available", data: nil)
        case .surfaceNotFound:
            return .err(
                code: "not_found",
                message: "Surface not found",
                data: .object(["surface_id": .string(surfaceID.uuidString)])
            )
        case .located(let snapshot):
            source = snapshot
        }

        var targetWindowID = source.windowID
        var targetWorkspaceID = source.workspaceID
        var destinationPaneID = source.defaultDestinationPaneID
        var targetIndex = plan.explicitIndex

        switch plan.routing {
        case .anchor(let anchorSurfaceID):
            guard let anchor = context.controlSurfaceMoveLocateAnchor(surfaceID: anchorSurfaceID) else {
                return .err(
                    code: "not_found",
                    message: "Anchor surface not found",
                    data: .object(["surface_id": .string(anchorSurfaceID.uuidString)])
                )
            }
            targetWindowID = anchor.windowID
            targetWorkspaceID = anchor.workspaceID
            destinationPaneID = anchor.paneID
            targetIndex = plan.anchorDestinationIndex(anchor.index)

        case .pane(let paneID):
            guard let located = context.controlSurfaceMoveLocatePane(paneID: paneID) else {
                return .err(
                    code: "not_found",
                    message: "Pane not found",
                    data: .object(["pane_id": .string(paneID.uuidString)])
                )
            }
            targetWindowID = located.windowID
            targetWorkspaceID = located.workspaceID
            destinationPaneID = located.paneID

        case .workspace(let workspaceID):
            guard let located = context.controlSurfaceMoveLocateWorkspace(workspaceID: workspaceID) else {
                return .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: .object(["workspace_id": .string(workspaceID.uuidString)])
                )
            }
            targetWorkspaceID = located.workspaceID
            targetWindowID = located.windowID ?? targetWindowID
            destinationPaneID = located.destinationPaneID

        case .window(let windowID):
            switch context.controlSurfaceMoveLocateWindow(windowID: windowID) {
            case .windowNotFound:
                return .err(
                    code: "not_found",
                    message: "Window not found",
                    data: .object(["window_id": .string(windowID.uuidString)])
                )
            case .noSelectedWorkspace:
                return .err(
                    code: "not_found",
                    message: "Target window has no selected workspace",
                    data: .object(["window_id": .string(windowID.uuidString)])
                )
            case .resolved(let workspaceID, let paneID):
                targetWindowID = windowID
                targetWorkspaceID = workspaceID
                destinationPaneID = paneID
            }

        case .source:
            break
        }

        guard let destinationPaneID else {
            return .err(code: "not_found", message: "No destination pane", data: nil)
        }

        switch ControlSurfaceMoveResolution.decide(
            sourceWorkspaceID: source.workspaceID,
            targetWorkspaceID: targetWorkspaceID
        ) {
        case .sameWorkspace:
            guard context.controlSurfaceMovePerformMove(
                workspaceID: targetWorkspaceID,
                surfaceID: surfaceID,
                destinationPaneID: destinationPaneID,
                index: targetIndex,
                requestedFocus: requestedFocus
            ) else {
                return .err(code: "internal_error", message: "Failed to move surface", data: nil)
            }
            return .ok(surfaceMoveSuccessPayload(
                windowID: targetWindowID,
                workspaceID: targetWorkspaceID,
                paneID: destinationPaneID,
                surfaceID: surfaceID
            ))

        case .crossWorkspace:
            switch context.controlSurfaceMovePerformTransfer(
                sourceWorkspaceID: source.workspaceID,
                sourcePaneID: source.paneID,
                sourceIndex: source.index,
                targetWorkspaceID: targetWorkspaceID,
                targetWindowID: targetWindowID,
                surfaceID: surfaceID,
                destinationPaneID: destinationPaneID,
                index: targetIndex,
                requestedFocus: requestedFocus
            ) {
            case .detachFailed:
                return .err(code: "internal_error", message: "Failed to detach surface", data: nil)
            case .attachFailed:
                return .err(code: "internal_error", message: "Failed to attach surface to destination", data: nil)
            case .transferred:
                return .ok(surfaceMoveSuccessPayload(
                    windowID: targetWindowID,
                    workspaceID: targetWorkspaceID,
                    paneID: destinationPaneID,
                    surfaceID: surfaceID
                ))
            }
        }
    }

    /// The eight-key `{window,workspace,pane,surface}_id`/`_ref` payload both move
    /// branches echo on success, byte-identical to the legacy `v2SurfaceMove`
    /// `.ok` body (the `_ref` values minted through the shared handle registry).
    ///
    /// - Parameters:
    ///   - windowID: The destination window id.
    ///   - workspaceID: The destination workspace id.
    ///   - paneID: The destination pane id.
    ///   - surfaceID: The moved surface id.
    /// - Returns: The success payload.
    private func surfaceMoveSuccessPayload(
        windowID: UUID,
        workspaceID: UUID,
        paneID: UUID,
        surfaceID: UUID
    ) -> JSONValue {
        .object([
            "window_id": .string(windowID.uuidString),
            "window_ref": ref(.window, windowID),
            "workspace_id": .string(workspaceID.uuidString),
            "workspace_ref": ref(.workspace, workspaceID),
            "pane_id": .string(paneID.uuidString),
            "pane_ref": ref(.pane, paneID),
            "surface_id": .string(surfaceID.uuidString),
            "surface_ref": ref(.surface, surfaceID),
        ])
    }
}
