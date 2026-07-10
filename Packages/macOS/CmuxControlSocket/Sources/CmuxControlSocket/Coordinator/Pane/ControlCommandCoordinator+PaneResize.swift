internal import Foundation

extension ControlCommandCoordinator {
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
        let resolution = context?.controlPaneResize(routing: routing, inputs: inputs) ?? .tabManagerUnavailable
        return paneResizeResult(resolution)
    }

    private func paneResizeResult(_ resolution: ControlPaneResizeResolution) -> ControlCallResult {
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
                "window_id": orNull(windowID?.uuidString), "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString), "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString), "pane_ref": ref(.pane, paneID),
                "split_id": .string(splitID.uuidString), "absolute_axis": .string(axis),
                "target_pixels": .double(targetPixels), "old_divider_position": .double(old),
                "new_divider_position": .double(new),
            ]))
        case .relativeResized(let windowID, let workspaceID, let paneID, let splitID, let direction, let amount, let old, let new):
            return .ok(.object([
                "window_id": orNull(windowID?.uuidString), "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString), "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString), "pane_ref": ref(.pane, paneID),
                "split_id": .string(splitID.uuidString), "direction": .string(direction),
                "amount": .int(Int64(amount)), "old_divider_position": .double(old),
                "new_divider_position": .double(new),
            ]))
        }
    }
}
