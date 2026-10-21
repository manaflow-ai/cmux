import Foundation

extension CMUXCLI {
    func tmuxResizePaneToSize(
        workspaceId: String,
        paneId: String,
        targetSize: String,
        absoluteAxis: String,
        client: SocketClient
    ) throws {
        let trimmed = targetSize.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPercentage = trimmed.hasSuffix("%")
        let numericText = isPercentage ? String(trimmed.dropLast()) : trimmed
        guard let target = Int(numericText), target > 0 else { return }
        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        let pane = panes.first(where: { ($0["id"] as? String) == paneId })
        let horizontal = absoluteAxis == "horizontal"
        let pointsKey = horizontal ? "cell_width_points" : "cell_height_points"
        let cellPoints = (pane?[pointsKey] as? NSNumber)?.doubleValue
            ?? pane?[pointsKey] as? Double

        let frame = panePayload["container_frame"] as? [String: Any]
        let dimensionKey = horizontal ? "width" : "height"
        let gridKey = horizontal ? "columns" : "rows"
        let containerExtent = (frame?[dimensionKey] as? NSNumber)?.doubleValue
            ?? frame?[dimensionKey] as? Double
        let gridCells = intFromAny(pane?[gridKey])
        let pixelFrame = pane?["pixel_frame"] as? [String: Any]
        let paneExtent = (pixelFrame?[dimensionKey] as? NSNumber)?.doubleValue
            ?? pixelFrame?[dimensionKey] as? Double
        let currentFraction: Double? = {
            guard horizontal,
                  let paneExtent,
                  let containerExtent,
                  paneExtent > 0,
                  containerExtent > 0 else { return nil }
            return paneExtent / containerExtent
        }()
        let targetPoints: Double?
        if isPercentage, let containerExtent, containerExtent > 0 {
            targetPoints = containerExtent * Double(target) / 100
        } else if !isPercentage,
                  let cellPoints, cellPoints > 0,
                  let gridCells, gridCells > 0,
                  let paneExtent, paneExtent > 0 {
            let residual = max(0, paneExtent - Double(gridCells) * cellPoints)
            targetPoints = Double(target) * cellPoints + residual
        } else {
            targetPoints = nil
        }
        if isPercentage,
           target == 30,
           let currentFraction,
           let shouldApply = try? tmuxShouldApplyMainVerticalLeaderWidth(
                workspaceId: workspaceId,
                paneId: paneId,
                currentFraction: currentFraction,
                targetFraction: 0.30,
                client: client
           ),
           !shouldApply {
            return
        }
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "pane_id": paneId,
            "absolute_axis": absoluteAxis,
            "tmux_compat": true,
        ]
        if let targetPoints {
            params["target_pixels"] = targetPoints
        }
        params[isPercentage ? "target_percentage" : "target_cells"] = target
        _ = try client.sendV2(method: "pane.resize", params: params)
    }

    /// Claude's main-vertical flow repeats `resize-pane -x 30%` after every
    /// teammate. Remember the first automatic width and treat later repeats as
    /// layout bookkeeping, while adopting a width changed by the user.
    private func tmuxShouldApplyMainVerticalLeaderWidth(
        workspaceId: String,
        paneId: String,
        currentFraction: Double,
        targetFraction: Double,
        client: SocketClient
    ) throws -> Bool {
        let store = try loadTmuxCompatStore()
        guard let layout = store.mainVerticalLayouts[workspaceId],
              let mainSurfaceId = try? tmuxCanonicalSurfaceId(
                    layout.mainSurfaceId,
                    workspaceId: workspaceId,
                    client: client
              ),
              let mainPaneId = try? tmuxPaneIdForSurface(
                    workspaceId: workspaceId,
                    surfaceId: mainSurfaceId,
                    client: client
              ),
              mainPaneId == paneId else {
            return true
        }

        var shouldApply = true
        try withLockedTmuxCompatStore { store in
            guard var currentLayout = store.mainVerticalLayouts[workspaceId] else { return }
            let epsilon = 0.02
            if abs(targetFraction - 0.30) <= epsilon,
               let remembered = currentLayout.mainPaneWidthFraction {
                if abs(currentFraction - remembered) > epsilon {
                    currentLayout.mainPaneWidthFraction = currentFraction
                    store.mainVerticalLayouts[workspaceId] = currentLayout
                }
                shouldApply = false
                return
            }
            currentLayout.mainPaneWidthFraction = targetFraction
            store.mainVerticalLayouts[workspaceId] = currentLayout
        }
        return shouldApply
    }

    func tmuxResizePaneByCells(
        workspaceId: String,
        paneId: String,
        direction: String,
        amountCells: Int,
        client: SocketClient
    ) throws {
        let panePayload = try client.sendV2(method: "pane.list", params: ["workspace_id": workspaceId])
        let panes = panePayload["panes"] as? [[String: Any]] ?? []
        let pane = panes.first(where: { ($0["id"] as? String) == paneId })
        let horizontal = direction == "left" || direction == "right"
        let pointsKey = horizontal ? "cell_width_points" : "cell_height_points"
        let cellPoints = (pane?[pointsKey] as? NSNumber)?.doubleValue
            ?? pane?[pointsKey] as? Double
        var params: [String: Any] = [
            "workspace_id": workspaceId,
            "pane_id": paneId,
            "direction": direction,
            "amount_cells": amountCells,
            "tmux_compat": true,
        ]
        if let cellPoints, cellPoints > 0 {
            let pointDelta = Double(amountCells) * cellPoints
            params["amount"] = NSNumber(value: pointDelta.rounded()).intValue
        }
        _ = try client.sendV2(method: "pane.resize", params: params)
    }
}
