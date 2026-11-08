internal import Foundation

extension ControlCommandCoordinator {
    /// `pane.resize` — move a split divider (relative or absolute).
    func paneResize(_ params: [String: JSONValue]) -> ControlCallResult {
        let routing = routingSelectors(params)
        guard let context, context.controlPaneRoutingResolvesTabManager(routing: routing) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }
        let invalidParameters = context.controlPaneResizeInvalidParametersMessage()

        let absoluteAxis = string(params, "absolute_axis")?.lowercased()
        let targetPixels = double(params, "target_pixels")
        let targetCells = strictInt(params, "target_cells")
        let targetPercentage = strictInt(params, "target_percentage")
        let directionRaw = (string(params, "direction") ?? "").lowercased()
        let amount = strictInt(params, "amount")
        let amountCells = strictInt(params, "amount_cells")
        let parsedTmuxCompatibility = bool(params, "tmux_compat")
        guard !params.keys.contains("target_cells") || (targetCells ?? 0) > 0 else {
            return .err(code: "invalid_params", message: invalidParameters, data: nil)
        }
        guard !params.keys.contains("target_percentage") || (targetPercentage ?? 0) > 0 else {
            return .err(code: "invalid_params", message: invalidParameters, data: nil)
        }
        guard !params.keys.contains("amount") || (amount ?? 0) > 0 else {
            return .err(code: "invalid_params", message: invalidParameters, data: nil)
        }
        guard !params.keys.contains("amount_cells") || (amountCells ?? 0) > 0 else {
            return .err(code: "invalid_params", message: invalidParameters, data: nil)
        }
        guard !params.keys.contains("tmux_compat") || parsedTmuxCompatibility != nil else {
            return .err(code: "invalid_params", message: invalidParameters, data: nil)
        }
        let tmuxCompatibility = parsedTmuxCompatibility ?? false
        let directionValid = ["left", "right", "up", "down"].contains(directionRaw)
        let hasAbsoluteIntent = params.keys.contains("absolute_axis")
            || params.keys.contains("target_pixels")
            || params.keys.contains("target_cells")
            || params.keys.contains("target_percentage")
        if hasAbsoluteIntent {
            guard let absoluteAxis, absoluteAxis == "horizontal" || absoluteAxis == "vertical" else {
                return .err(code: "invalid_params", message: "absolute_axis must be 'horizontal' or 'vertical'", data: nil)
            }
            guard !params.keys.contains("target_pixels")
                    || (targetPixels?.isFinite == true && (targetPixels ?? 0) > 0) else {
                return .err(code: "invalid_params", message: "target_pixels must be > 0", data: nil)
            }
            guard !params.keys.contains("amount_cells") else {
                return .err(code: "invalid_params", message: invalidParameters, data: nil)
            }
            if tmuxCompatibility {
                guard (targetCells != nil) != (targetPercentage != nil) else {
                    return .err(code: "invalid_params", message: invalidParameters, data: nil)
                }
            } else {
                guard let targetPixels, targetPixels.isFinite, targetPixels > 0,
                      targetCells == nil, targetPercentage == nil else {
                    return .err(code: "invalid_params", message: invalidParameters, data: nil)
                }
            }
        } else {
            guard directionValid else {
                return .err(code: "invalid_params", message: "direction must be one of left|right|up|down and amount must be > 0", data: nil)
            }
            if tmuxCompatibility {
                guard amountCells != nil else {
                    return .err(code: "invalid_params", message: invalidParameters, data: nil)
                }
            } else {
                guard (amount ?? 1) > 0, amountCells == nil else {
                    return .err(code: "invalid_params", message: invalidParameters, data: nil)
                }
            }
        }

        let intent: ControlPaneResizeIntent
        if let absoluteAxis {
            if tmuxCompatibility, let targetPercentage {
                intent = .tmuxAbsolutePercentage(
                    axis: absoluteAxis,
                    percentage: targetPercentage,
                    fallbackPoints: targetPixels
                )
            } else if tmuxCompatibility, let targetCells {
                intent = .tmuxAbsoluteCells(
                    axis: absoluteAxis,
                    targetCells: targetCells,
                    fallbackPoints: targetPixels
                )
            } else if let targetPixels {
                intent = .outerAbsolute(axis: absoluteAxis, targetPoints: targetPixels)
            } else {
                return .err(code: "invalid_params", message: invalidParameters, data: nil)
            }
        } else if tmuxCompatibility, let amountCells {
            intent = .tmuxRelative(
                direction: directionRaw,
                amountCells: amountCells,
                fallbackPoints: amount
            )
        } else {
            intent = .borderRelative(direction: directionRaw, amountPoints: amount ?? 1)
        }
        let inputs = ControlPaneResizeInputs(paneID: uuid(params, "pane_id"), intent: intent)
        let resolution = context.controlPaneResize(routing: routing, inputs: inputs)
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
        case .remoteResizeUnavailable(let paneID, let message):
            return .err(
                code: "unavailable",
                message: message,
                data: .object(["pane_id": .string(paneID.uuidString)])
            )
        case .localResizeUnavailable(let paneID, let message):
            return .err(
                code: "unavailable",
                message: message,
                data: .object(["pane_id": .string(paneID.uuidString)])
            )
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
        case .remoteAbsoluteResizeRequested(let windowID, let workspaceID, let paneID, let axis, let targetPixels):
            var payload: [String: JSONValue] = [
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "absolute_axis": .string(axis),
                "remote": .bool(true),
            ]
            if let targetPixels {
                payload["target_pixels"] = .double(targetPixels)
            }
            return .ok(.object(payload))
        case .remoteRelativeResizeRequested(let windowID, let workspaceID, let paneID, let direction, let amount):
            var payload: [String: JSONValue] = [
                "window_id": orNull(windowID?.uuidString),
                "window_ref": ref(.window, windowID),
                "workspace_id": .string(workspaceID.uuidString),
                "workspace_ref": ref(.workspace, workspaceID),
                "pane_id": .string(paneID.uuidString),
                "pane_ref": ref(.pane, paneID),
                "direction": .string(direction),
                "remote": .bool(true),
            ]
            if let amount {
                payload["amount"] = .int(Int64(amount))
            }
            return .ok(.object(payload))
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
}
