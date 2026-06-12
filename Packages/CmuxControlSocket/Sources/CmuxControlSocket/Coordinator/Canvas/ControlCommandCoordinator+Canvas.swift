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
            ])
        }
        return .ok(.object([
            "workspace_id": .string(snapshot.workspaceID.uuidString),
            "workspace_ref": ref(.workspace, snapshot.workspaceID),
            "mode": .string(snapshot.mode),
            "panes": .array(panes),
        ]))
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

    // MARK: - Shared resolution mapping

    private func canvasActionResult(_ resolution: ControlCanvasActionResolution) -> ControlCallResult {
        switch resolution {
        case .ok(let mode):
            return .ok(.object(["mode": .string(mode)]))
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
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
