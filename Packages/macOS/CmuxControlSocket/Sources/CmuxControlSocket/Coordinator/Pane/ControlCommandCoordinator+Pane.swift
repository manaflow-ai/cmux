internal import Foundation

/// The pane domain (`pane.*`), lifted byte-faithfully from the former
/// `TerminalController.v2Pane*` bodies. Each payload is built directly as a
/// ``JSONValue`` (the typed twin of the legacy `[String: Any]` dictionaries);
/// the resulting Foundation object is identical, so the encoded wire bytes
/// match. The coordinator owns the param parsing and ref minting; the app-coupled
/// work (Bonsplit layout, split creation/resize, surface moves) runs behind the
/// ``ControlPaneContext`` seam.
extension ControlCommandCoordinator {

    /// Runs one decoded request if it belongs to the pane domain, returning the
    /// typed result; returns `nil` otherwise so the caller can fall through. The
    /// integrator calls this from the core `handle`.
    ///
    /// - Parameter request: The decoded request envelope.
    /// - Returns: The command result, or `nil` if not a pane method.
    func handlePane(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "pane.list":
            // Worker-lane resolution read (tranche D): the nonisolated body is
            // shared with the socket dispatcher's worker lane; from this
            // main-actor dispatch its hop collapses inline.
            return paneList(request.params, context: context)
        case "pane.focus":
            return paneFocus(request.params)
        case "pane.surfaces":
            return paneSurfaces(request.params, context: context)
        case "pane.create":
            return paneCreate(request.params)
        case "pane.resize":
            return paneResize(request.params)
        case "pane.swap":
            return paneSwap(request.params)
        case "pane.break":
            return paneBreak(request.params)
        case "pane.join":
            return paneJoin(request.params)
        case "pane.last":
            return paneLast(request.params)
        default:
            return nil
        }
    }

    // MARK: - list

    /// The per-row refs of one `pane.list` item, minted in the row's literal
    /// order (pane, surface_refs array, selected surface).
    private struct PaneListRowRefs: Sendable {
        let paneRef: JSONValue
        let surfaceRefs: [JSONValue]
        let selectedSurfaceRef: JSONValue
    }

    /// The `pane.list` hop outcome.
    private enum PaneListHopOutcome: Sendable {
        case tabManagerUnavailable
        case workspaceNotFound
        case listed(
            snapshot: ControlPaneListSnapshot,
            paneRefs: [PaneListRowRefs],
            workspaceRef: JSONValue,
            windowRef: JSONValue
        )
    }

    /// `pane.list` — the resolved workspace's pane layout.
    ///
    /// Worker-lane resolution read (tranche D of issue #5757): routing
    /// resolution, the snapshot witness (whose `ghostty_surface_size` reads
    /// must stay on main), and ref minting take ONE `controlResolveOnMain` hop
    /// (which refreshes known refs first, exactly like the main-lane dispatch
    /// preamble); the per-pane JSON row build and the reply encode run on the
    /// calling socket-worker thread. Refs mint in the payload's literal order
    /// (per row: pane, surface_refs, selected surface; then workspace, then
    /// window).
    nonisolated func paneList(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let outcome: PaneListHopOutcome = context.controlResolveOnMain { seam in
            let routing = self.routingSelectors(params)
            guard seam.controlPaneRoutingResolvesTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let snapshot = seam.controlPaneList(routing: routing) else {
                return .workspaceNotFound
            }
            let paneRefs = snapshot.panes.map { pane in
                PaneListRowRefs(
                    paneRef: self.ref(.pane, pane.paneID),
                    surfaceRefs: pane.surfaceIDs.map { self.ref(.surface, $0) },
                    selectedSurfaceRef: self.ref(.surface, pane.selectedSurfaceID)
                )
            }
            return .listed(
                snapshot: snapshot,
                paneRefs: paneRefs,
                workspaceRef: self.ref(.workspace, snapshot.workspaceID),
                windowRef: self.ref(.window, snapshot.windowID)
            )
        }
        switch outcome {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case let .listed(snapshot, paneRefs, workspaceRef, windowRef):
            return paneListPayload(
                snapshot: snapshot,
                paneRefs: paneRefs,
                workspaceRef: workspaceRef,
                windowRef: windowRef
            )
        }
    }

    /// The off-main `pane.list` payload build over the hop's snapshot and
    /// pre-minted refs.
    private nonisolated func paneListPayload(
        snapshot: ControlPaneListSnapshot,
        paneRefs: [PaneListRowRefs],
        workspaceRef: JSONValue,
        windowRef: JSONValue
    ) -> ControlCallResult {
        let panes: [JSONValue] = snapshot.panes.enumerated().map { index, pane in
            var dict: [String: JSONValue] = [
                "id": .string(pane.paneID.uuidString),
                "ref": paneRefs[index].paneRef,
                "index": .int(Int64(index)),
                "focused": .bool(pane.isFocused),
                "surface_ids": .array(pane.surfaceIDs.map { .string($0.uuidString) }),
                "surface_refs": .array(paneRefs[index].surfaceRefs),
                "selected_surface_id": orNull(pane.selectedSurfaceID?.uuidString),
                "selected_surface_ref": paneRefs[index].selectedSurfaceRef,
                "surface_count": .int(Int64(pane.surfaceIDs.count)),
            ]
            if let frame = pane.pixelFrame {
                dict["pixel_frame"] = .object([
                    "x": .double(frame.x),
                    "y": .double(frame.y),
                    "width": .double(frame.width),
                    "height": .double(frame.height),
                ])
            }
            if let grid = pane.gridSize {
                dict["columns"] = .int(Int64(grid.columns))
                dict["rows"] = .int(Int64(grid.rows))
                dict["cell_width_px"] = .int(Int64(grid.cellWidthPx))
                dict["cell_height_px"] = .int(Int64(grid.cellHeightPx))
            }
            return .object(dict)
        }

        return .ok(.object([
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": workspaceRef,
            "panes": .array(panes),
            "window_id": orNull(snapshot.windowID?.uuidString),
            "window_ref": windowRef,
            "container_frame": .object([
                "width": .double(snapshot.containerWidth),
                "height": .double(snapshot.containerHeight),
            ]),
        ]))
    }

    // MARK: - focus

    /// `pane.focus` — focus a pane in the resolved workspace.
    func paneFocus(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlPaneRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        guard let paneID = uuid(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }
        let resolution = context?.controlPaneFocus(routing: routing, paneID: paneID)
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .paneNotFound(let id):
            return .err(
                code: "not_found",
                message: "Pane not found",
                data: .object(["pane_id": .string(id.uuidString)])
            )
        case .focused(let windowID, let workspaceID, let focusedPaneID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(focusedPaneID.uuidString),
                "pane_ref": ref(.pane, focusedPaneID),
            ]))
        }
    }

    // MARK: - surfaces

    /// The `pane.surfaces` hop outcome (refs minted in the payload's literal
    /// order: per-row surface refs, then workspace, pane, window).
    private enum PaneSurfacesHopOutcome: Sendable {
        case tabManagerUnavailable
        case paneOrWorkspaceNotFound
        case resolved(
            snapshot: ControlPaneSurfacesSnapshot,
            surfaceRefs: [JSONValue],
            workspaceRef: JSONValue,
            paneRef: JSONValue,
            windowRef: JSONValue
        )
    }

    /// `pane.surfaces` — the surfaces in one pane.
    /// Worker-lane resolution read; see ``paneList(_:context:)``. The
    /// `pane_id` param resolves through the handle registry, so its parse
    /// stays inside the hop too.
    nonisolated func paneSurfaces(
        _ params: [String: JSONValue],
        context: (any ControlCommandContext)?
    ) -> ControlCallResult {
        guard let context else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let outcome: PaneSurfacesHopOutcome = context.controlResolveOnMain { seam in
            let routing = self.routingSelectors(params)
            guard seam.controlPaneRoutingResolvesTabManager(routing: routing) else {
                return .tabManagerUnavailable
            }
            guard let snapshot = seam.controlPaneSurfaces(
                routing: routing,
                paneID: self.uuid(params, "pane_id")
            ) else {
                return .paneOrWorkspaceNotFound
            }
            return .resolved(
                snapshot: snapshot,
                surfaceRefs: snapshot.surfaces.map { self.ref(.surface, $0.surfaceID) },
                workspaceRef: self.ref(.workspace, snapshot.workspaceID),
                paneRef: self.ref(.pane, snapshot.paneID),
                windowRef: self.ref(.window, snapshot.windowID)
            )
        }
        switch outcome {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .paneOrWorkspaceNotFound:
            return .err(code: "not_found", message: "Pane or workspace not found", data: nil)
        case let .resolved(snapshot, surfaceRefs, workspaceRef, paneRef, windowRef):
            let surfaces: [JSONValue] = snapshot.surfaces.enumerated().map { index, surface in
                .object([
                    "id": orNull(surface.surfaceID?.uuidString),
                    "ref": surfaceRefs[index],
                    "index": .int(Int64(index)),
                    "title": .string(surface.title),
                    "type": orNull(surface.typeRawValue),
                    "selected": .bool(surface.isSelected),
                ])
            }

            return .ok(.object([
                "workspace_id": .string(snapshot.workspaceID.uuidString),
                "workspace_ref": workspaceRef,
                "pane_id": .string(snapshot.paneID.uuidString),
                "pane_ref": paneRef,
                "surfaces": .array(surfaces),
                "window_id": orNull(snapshot.windowID?.uuidString),
                "window_ref": windowRef,
            ]))
        }
    }

    // MARK: - create

    /// `pane.create` — split the source surface into a new pane.
    func paneCreate(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlPaneRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let inputs = ControlPaneCreateInputs(
            directionRaw: string(params, "direction"),
            typeRaw: string(params, "type"),
            urlRaw: string(params, "url"),
            workingDirectory: optionalTrimmedRawString(params, "working_directory"),
            initialCommand: optionalTrimmedRawString(params, "initial_command"),
            tmuxStartCommand: optionalTrimmedRawString(params, "tmux_start_command"),
            startupEnvironment: trimmedStringMap(params, keys: ["startup_environment", "initial_env"]),
            requestedSourceSurfaceID: string(params, "surface_id").flatMap(UUID.init(uuidString:)),
            requestedFocus: bool(params, "focus") ?? false,
            hasInitialDividerPosition: hasNonNull(params, "initial_divider_position"),
            initialDividerPositionRaw: double(params, "initial_divider_position"),
            placementRaw: string(params, "placement")
        )

        let resolution = context?.controlPaneCreate(routing: routing, inputs: inputs)
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .invalidDirection:
            return .err(
                code: "invalid_params",
                message: "Missing or invalid direction (left|right|up|down)",
                data: nil
            )
        case .invalidDividerPosition:
            return .err(
                code: "invalid_params",
                message: "initial_divider_position must be numeric",
                data: nil
            )
        case .invalidPlacement(let rawValue):
            return .err(
                code: "invalid_params",
                message: "placement must be one of: workspace, dock",
                data: .object(["placement": .string(rawValue)])
            )
        case .agentSessionRejected(let typeRawValue):
            return .err(code: "invalid_params", message: "agent-session is only supported by surface.create", data: .object(["type": .string(typeRawValue)]))
        case .dockUnsupportedType(let typeRawValue, let message):
            return .err(code: "invalid_params", message: message, data: .object(["type": .string(typeRawValue)]))
        case .dockUnavailable(let message): return .err(code: "invalid_params", message: message, data: .object(["placement": .string("dock")]))
        case .dockConflictingRoutingSelectors(let message): return .err(code: "invalid_params", message: message, data: nil)
        case .browserDisabledInvalidURL(let rawURL):
            return .err(code: "invalid_params", message: "Invalid URL", data: .object(["url": .string(rawURL)]))
        case .browserDisabledNoURL:
            return .err(code: "browser_disabled", message: "cmux browser is disabled", data: nil)
        case .browserDisabledExternalOpenFailed(let url):
            return .err(
                code: "external_open_failed",
                message: "Failed to open URL externally",
                data: .object(["url": .string(url)])
            )
        case .browserDisabledOpenedExternally(let windowID, let url):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .null,
                "workspace_ref": .null,
                "pane_id": .null,
                "pane_ref": .null,
                "surface_id": .null,
                "surface_ref": .null,
                "created_split": .bool(false),
                "opened_externally": .bool(true),
                "browser_disabled": .bool(true),
                "placement_strategy": .string("external_browser_disabled"),
                "url": .string(url),
            ]))
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noSourceSurface:
            return .err(code: "not_found", message: "No source surface to split", data: nil)
        case .createFailed:
            return .err(code: "internal_error", message: "Failed to create pane", data: nil)
        case .mirrorUnsupportedOptions(let unsupported):
            return mirrorUnsupportedOptionsResult(unsupported)
        case .routedToRemote(let windowID, let workspaceID, let typeRawValue):
            return remoteRoutedCreationResult(
                windowID: windowID,
                workspaceID: workspaceID,
                typeRawValue: typeRawValue
            )
        case .createdDock(let windowID, let workspaceID, let dockPaneID, let dockSurfaceID, let typeRawValue):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "placement": .string("dock"),
                "pane_id": .null,
                "pane_ref": .null,
                "surface_id": .null,
                "surface_ref": .null,
                "dock_pane_id": orNull(dockPaneID?.uuidString),
                "dock_surface_id": .string(dockSurfaceID.uuidString),
                "type": .string(typeRawValue),
            ]))
        case .created(let windowID, let workspaceID, let paneID, let surfaceID, let typeRawValue):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": orNull(paneID?.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
                "type": .string(typeRawValue),
            ]))
        }
    }

    // MARK: - resize

    /// `pane.resize` — move a split divider (relative or absolute).
    func paneResize(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlPaneRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let absoluteAxis = string(params, "absolute_axis")?.lowercased()
        let targetPixels = double(params, "target_pixels")
        let directionRaw = (string(params, "direction") ?? "").lowercased()
        let amount = int(params, "amount") ?? 1
        let directionValid = ["left", "right", "up", "down"].contains(directionRaw)
        let hasAbsoluteIntent = params.keys.contains("absolute_axis") || params.keys.contains("target_pixels")
        if hasAbsoluteIntent {
            guard let absoluteAxis, absoluteAxis == "horizontal" || absoluteAxis == "vertical" else {
                return .err(code: "invalid_params", message: "absolute_axis must be 'horizontal' or 'vertical'", data: nil)
            }
            guard let targetPixels, targetPixels > 0 else {
                return .err(code: "invalid_params", message: "target_pixels must be > 0", data: nil)
            }
        } else {
            guard directionValid, amount > 0 else {
                return .err(code: "invalid_params", message: "direction must be one of left|right|up|down and amount must be > 0", data: nil)
            }
        }

        let inputs = ControlPaneResizeInputs(
            paneID: uuid(params, "pane_id"),
            absoluteAxis: absoluteAxis,
            targetPixels: targetPixels,
            direction: directionValid ? directionRaw : nil,
            amount: amount
        )
        let resolution = context?.controlPaneResize(routing: routing, inputs: inputs)
            ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedPane:
            return .err(code: "not_found", message: "No focused pane", data: nil)
        case .paneNotFound(let id):
            return .err(code: "not_found", message: "Pane not found", data: .object(["pane_id": .string(id.uuidString)]))
        case .paneNotFoundInTree(let id):
            return .err(code: "not_found", message: "Pane not found in split tree", data: .object(["pane_id": .string(id.uuidString)]))
        case .noAbsoluteSplitAncestor(let paneID, let axis):
            return .err(
                code: "invalid_state",
                message: "No split ancestor for absolute pane resize",
                data: .object(["pane_id": .string(paneID.uuidString), "absolute_axis": orNull(axis)])
            )
        case .noOrientationSplitAncestor(let paneID, let orientation, let direction):
            return .err(
                code: "invalid_state",
                message: "No \(orientation) split ancestor for pane",
                data: .object(["pane_id": .string(paneID.uuidString), "direction": .string(direction)])
            )
        case .noAdjacentBorder(let paneID, let direction):
            return .err(
                code: "invalid_state",
                message: "Pane has no adjacent border in direction \(direction)",
                data: .object(["pane_id": .string(paneID.uuidString), "direction": .string(direction)])
            )
        case .setDividerFailed(let splitID):
            return .err(
                code: "internal_error",
                message: "Failed to set split divider position",
                data: .object(["split_id": .string(splitID.uuidString)])
            )
        case .absoluteResized(let windowID, let workspaceID, let paneID, let splitID, let axis, let targetPixels, let old, let new):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "split_id": .string(splitID.uuidString),
                "absolute_axis": .string(axis),
                "target_pixels": .double(targetPixels),
                "old_divider_position": .double(old),
                "new_divider_position": .double(new),
            ]))
        case .relativeResized(let windowID, let workspaceID, let paneID, let splitID, let direction, let amount, let old, let new):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "split_id": .string(splitID.uuidString),
                "direction": .string(direction),
                "amount": .int(Int64(amount)),
                "old_divider_position": .double(old),
                "new_divider_position": .double(new),
            ]))
        }
    }

    // MARK: - swap

    /// `pane.swap` — swap the selected surfaces of two panes.
    func paneSwap(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let sourcePaneID = uuid(params, "pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid pane_id", data: nil)
        }
        guard let targetPaneID = uuid(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }
        if sourcePaneID == targetPaneID {
            return .err(code: "invalid_params", message: "pane_id and target_pane_id must be different", data: nil)
        }
        let resolution = context?.controlPaneSwap(
            sourcePaneID: sourcePaneID,
            targetPaneID: targetPaneID,
            requestedFocus: bool(params, "focus") ?? false
        )
        guard let resolution else {
            return .err(code: "internal_error", message: "Failed to swap panes", data: nil)
        }
        switch resolution {
        case .sourcePaneNotFound(let id):
            return .err(code: "not_found", message: "Source pane not found", data: .object(["pane_id": .string(id.uuidString)]))
        case .targetPaneNotFound(let id):
            return .err(code: "not_found", message: "Target pane not found in source workspace", data: .object(["target_pane_id": .string(id.uuidString)]))
        case .bothPanesNeedSurface:
            return .err(code: "invalid_state", message: "Both panes must have a selected surface", data: nil)
        case .sourcePlaceholderFailed:
            return .err(code: "internal_error", message: "Failed to create source placeholder surface", data: nil)
        case .targetPlaceholderFailed:
            return .err(code: "internal_error", message: "Failed to create target placeholder surface", data: nil)
        case .moveSourceFailed:
            return .err(code: "internal_error", message: "Failed moving source surface into target pane", data: nil)
        case .moveTargetFailed:
            return .err(code: "internal_error", message: "Failed moving target surface into source pane", data: nil)
        case .swapped(let windowID, let workspaceID, let sourcePane, let targetPane, let sourceSurface, let targetSurface):
            return .ok(.object([
                "window_id": .string(windowID.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(sourcePane.uuidString),
                "pane_ref": ref(.pane, sourcePane),
                "target_pane_id": .string(targetPane.uuidString),
                "target_pane_ref": ref(.pane, targetPane),
                "source_surface_id": .string(sourceSurface.uuidString),
                "source_surface_ref": ref(.surface, sourceSurface),
                "target_surface_id": .string(targetSurface.uuidString),
                "target_surface_ref": ref(.surface, targetSurface),
            ]))
        }
    }

    // MARK: - break

    /// `pane.break` — detach a surface into a new workspace.
    func paneBreak(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlPaneRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlPaneBreak(
            routing: routing,
            paneID: uuid(params, "pane_id"),
            surfaceID: uuid(params, "surface_id"),
            requestedFocus: bool(params, "focus") ?? false
        ) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noSourceSurface:
            return .err(code: "not_found", message: "No source surface to break", data: nil)
        case .surfaceNotFound(let id):
            return .err(code: "not_found", message: "Surface not found", data: .object(["surface_id": .string(id.uuidString)]))
        case .detachFailed:
            return .err(code: "internal_error", message: "Failed to detach source surface", data: nil)
        case .createWorkspaceFailed:
            return .err(code: "internal_error", message: "Failed to create workspace for detached surface", data: nil)
        case .destinationPaneUnresolved(let workspaceID, let surfaceID):
            return .err(
                code: "internal_error",
                message: "Failed to resolve destination pane for detached surface",
                data: .object([
                    "workspace_id": .string(workspaceID.uuidString),
                    "surface_id": .string(surfaceID.uuidString),
                ])
            )
        case .broken(let windowID, let workspaceID, let paneID, let surfaceID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        }
    }

    // MARK: - join

    /// `pane.join` — move a surface into a target pane (via surface-move logic).
    func paneJoin(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let targetPaneID = uuid(params, "target_pane_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_pane_id", data: nil)
        }
        let hasFocusParam = bool(params, "focus") != nil
        let resolution = context?.controlPaneJoin(
            targetPaneID: targetPaneID,
            surfaceID: uuid(params, "surface_id"),
            sourcePaneID: uuid(params, "pane_id"),
            hasFocusParam: hasFocusParam,
            focus: bool(params, "focus") ?? false
        )
        guard let resolution else {
            return .err(code: "invalid_params", message: "Missing surface_id (or pane_id with selected surface)", data: nil)
        }
        switch resolution {
        case .sourceSurfaceUnresolved(let sourcePaneID):
            return .err(
                code: "not_found",
                message: "Unable to resolve selected surface in source pane",
                data: .object(["pane_id": .string(sourcePaneID.uuidString)])
            )
        case .missingSurface:
            return .err(code: "invalid_params", message: "Missing surface_id (or pane_id with selected surface)", data: nil)
        case .moved(let result):
            return result
        }
    }

    // MARK: - last

    /// `pane.last` — focus the alternate pane.
    func paneLast(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard context?.controlPaneRoutingResolvesTabManager(routing: routing) ?? false else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let resolution = context?.controlPaneLast(routing: routing) ?? .tabManagerUnavailable
        switch resolution {
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .noFocusedPane:
            return .err(code: "not_found", message: "No focused pane", data: nil)
        case .noAlternatePane:
            return .err(code: "not_found", message: "No alternate pane available", data: nil)
        case .focused(let windowID, let workspaceID, let paneID, let selectedSurfaceID):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "surface_id": orNull(selectedSurfaceID?.uuidString),
                "surface_ref": ref(.surface, selectedSurfaceID),
            ]))
        }
    }
}
