internal import Foundation

/// The canvas domain (`canvas.*`): workspace canvas-layout introspection and
/// control. The coordinator owns param parsing and ref minting; the
/// app-coupled work (layout mode, canvas model mutations, viewport
/// scrolling) runs behind the ``ControlCanvasContext`` seam.
extension ControlCommandCoordinator {
    /// Runs one decoded request if it belongs to the canvas domain, returning
    /// the typed result; returns `nil` otherwise so the caller falls through.
    func handleCanvas(_ request: ControlRequest) -> ControlCallResult? {
        switch request.method {
        case "canvas.info":
            return canvasInfo(request.params)
        case "canvas.set_mode":
            return canvasSetMode(request.params)
        case "canvas.set_frame":
            return canvasSetFrame(request.params)
        case "canvas.align":
            return canvasAlign(request.params)
        case "canvas.reveal":
            return canvasReveal(request.params)
        case "canvas.overview":
            return canvasOverview(request.params)
        case "canvas.zoom":
            return canvasZoom(request.params)
        case "canvas.join":
            return canvasJoin(request.params)
        case "canvas.break":
            return canvasBreak(request.params)
        case "canvas.select_tab":
            return canvasSelectTab(request.params)
        case "canvas.set_viewport":
            return canvasSetViewport(request.params)
        case "canvas.new_pane":
            return canvasNewPane(request.params)
        default:
            return nil
        }
    }

    // MARK: - info

    /// `canvas.info` — the resolved workspace's layout mode and pane frames
    /// (z-order, back to front).
    func canvasInfo(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let snapshot = context?.controlCanvasInfo(routing: routing) else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        let panes: [JSONValue] = snapshot.panes.map { pane in
            .object([
                "surface_id": .string(pane.surfaceID.uuidString),
                "surface_ref": ref(.surface, pane.surfaceID),
                "x": .double(pane.frame.x),
                "y": .double(pane.frame.y),
                "width": .double(pane.frame.width),
                "height": .double(pane.frame.height),
                "focused": .bool(pane.isFocused),
                "surface_ids": .array(pane.panelIDs.map { .string($0.uuidString) }),
                "surface_refs": .array(pane.panelIDs.map { ref(.surface, $0) }),
                "selected_surface_id": .string(pane.selectedPanelID.uuidString),
                "selected_surface_ref": ref(.surface, pane.selectedPanelID),
            ])
        }
        var object: [String: JSONValue] = [
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "mode": .string(snapshot.mode),
            "panes": .array(panes),
        ]
        if let magnification = snapshot.magnification {
            object["magnification"] = .double(magnification)
        }
        if let centerX = snapshot.centerX, let centerY = snapshot.centerY {
            object["viewport_center"] = .object([
                "x": .double(centerX),
                "y": .double(centerY),
            ])
        }
        return .ok(.object(object))
    }

    // MARK: - set_mode

    /// `canvas.set_mode` — switch the workspace between `canvas`, `splits`,
    /// or `toggle`.
    func canvasSetMode(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let mode = string(params, "mode"),
              ["canvas", "splits", "toggle"].contains(mode) else {
            return .err(
                code: "invalid_params",
                message: "mode must be canvas, splits, or toggle",
                data: nil
            )
        }
        let routing = routingSelectors(params)
        let resolution = context?.controlCanvasSetMode(routing: routing, mode: mode)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - set_frame

    /// `canvas.set_frame` — place one pane at an explicit canvas frame. The
    /// target comes from the routing surface selector (`surface_id` /
    /// `surface_ref` / `tab_id`).
    func canvasSetFrame(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let surfaceID = routing.surfaceID else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let x = double(params, "x"),
              let y = double(params, "y"),
              let width = double(params, "width"),
              let height = double(params, "height"),
              width > 0, height > 0 else {
            return .err(
                code: "invalid_params",
                message: "x, y, width, height are required; width/height must be positive",
                data: nil
            )
        }
        let resolution = context?.controlCanvasSetFrame(
            routing: routing,
            surfaceID: surfaceID,
            frame: ControlCanvasFrame(x: x, y: y, width: width, height: height)
        ) ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - align

    /// `canvas.align` — run an alignment/distribution/tidy command.
    func canvasAlign(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let raw = string(params, "command"),
              let command = ControlCanvasAlignCommand(rawValue: raw) else {
            let known = ControlCanvasAlignCommand.allCases.map(\.rawValue).joined(separator: ", ")
            return .err(
                code: "invalid_params",
                message: "command must be one of: \(known)",
                data: nil
            )
        }
        let routing = routingSelectors(params)
        let resolution = context?.controlCanvasAlign(routing: routing, command: command)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - reveal

    /// `canvas.reveal` — scroll a pane into view (focused pane when no
    /// surface selector is given).
    func canvasReveal(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        let resolution = context?.controlCanvasReveal(routing: routing, surfaceID: routing.surfaceID)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - overview

    /// `canvas.overview` — toggle the fit-all overview zoom.
    func canvasOverview(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        let resolution = context?.controlCanvasToggleOverview(routing: routing)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - zoom

    /// `canvas.zoom` — step the viewport magnification (`in`/`out`/`reset`).
    func canvasZoom(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let raw = string(params, "direction"),
              let direction = ControlCanvasZoomDirection(rawValue: raw) else {
            return .err(
                code: "invalid_params",
                message: "direction must be in, out, or reset",
                data: nil
            )
        }
        let routing = routingSelectors(params)
        let resolution = context?.controlCanvasZoom(routing: routing, direction: direction)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - join / break / select_tab

    /// `canvas.join` — move a surface into the pane hosting another surface.
    func canvasJoin(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let surfaceID = routing.surfaceID else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        guard let targetSurfaceID = uuid(params, "target_surface_id") else {
            return .err(code: "invalid_params", message: "Missing or invalid target_surface_id", data: nil)
        }
        let resolution = context?.controlCanvasJoin(
            routing: routing,
            surfaceID: surfaceID,
            targetSurfaceID: targetSurfaceID
        ) ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    /// `canvas.break` — tear a surface out of its multi-tab pane.
    func canvasBreak(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let surfaceID = routing.surfaceID else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let resolution = context?.controlCanvasBreak(routing: routing, surfaceID: surfaceID)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    /// `canvas.select_tab` — select a surface as its pane's visible tab.
    func canvasSelectTab(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let surfaceID = routing.surfaceID else {
            return .err(code: "invalid_params", message: "Missing or invalid surface_id", data: nil)
        }
        let resolution = context?.controlCanvasSelectTab(routing: routing, surfaceID: surfaceID)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - set_viewport

    /// `canvas.set_viewport` — center the viewport on a canvas point and
    /// optionally set the magnification (`zoom`/`magnification`).
    func canvasSetViewport(_ params: [String: JSONValue]) -> ControlCallResult {
        guard let x = double(params, "x"), let y = double(params, "y") else {
            return .err(
                code: "invalid_params",
                message: "x and y are required",
                data: nil
            )
        }
        let magnification = double(params, "zoom") ?? double(params, "magnification")
        if let magnification, magnification <= 0 {
            return .err(
                code: "invalid_params",
                message: "zoom must be positive",
                data: nil
            )
        }
        let routing = routingSelectors(params)
        let resolution = context?.controlCanvasSetViewport(
            routing: routing,
            centerX: x,
            centerY: y,
            magnification: magnification
        ) ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - new_pane

    /// `canvas.new_pane` — create a new free-floating canvas pane (`type`
    /// defaults to `terminal`).
    func canvasNewPane(_ params: [String: JSONValue]) -> ControlCallResult {
        let type = string(params, "type") ?? "terminal"
        guard ["terminal", "browser"].contains(type) else {
            return .err(
                code: "invalid_params",
                message: "type must be terminal or browser",
                data: nil
            )
        }
        let routing = routingSelectors(params)
        let resolution = context?.controlCanvasNewPane(routing: routing, type: type)
            ?? .tabManagerUnavailable
        return canvasActionResult(resolution)
    }

    // MARK: - Shared resolution mapping

    private func canvasActionResult(_ resolution: ControlCanvasActionResolution) -> ControlCallResult {
        switch resolution {
        case .ok(let mode):
            return .ok(.object(["mode": .string(mode)]))
        case .created(let mode, let surfaceID):
            return .ok(.object([
                "mode": .string(mode),
                "surface_id": .string(surfaceID.uuidString),
                "surface_ref": ref(.surface, surfaceID),
            ]))
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "No active cmux window", data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        case .notCanvasMode:
            return .err(
                code: "invalid_state",
                message: "Workspace is not in canvas layout (run canvas.set_mode first)",
                data: nil
            )
        case .paneNotFound(let id):
            return .err(
                code: "not_found",
                message: "Canvas pane not found",
                data: .object(["surface_id": .string(id.uuidString)])
            )
        case .noFocusedPane:
            return .err(
                code: "invalid_state",
                message: "No focused pane to target (pass surface_id)",
                data: nil
            )
        }
    }
}
