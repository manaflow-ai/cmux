import CMUXMobileCore
import Foundation

extension TerminalController {
    nonisolated static let mobileScrollDirectionalRunLimit = 4_096

    /// Scrollback rows included in a cold-attach render-grid replay snapshot.
    /// Live render-grid events carry no scrollback; the phone keeps its own
    /// bounded Ghostty scrollback mirror and scrolls that mirror locally while
    /// the Mac remains authoritative.
    nonisolated static let mobileReplayScrollbackLineBudget = 240

    /// Larger history window returned only on explicit mobile scroll prefetch
    /// requests, keeping ordinary scroll RPCs small.
    nonisolated static let mobileScrollPrefetchScrollbackLineBudget = 600

    func mobileTerminalRenderGridFrame(
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        seq: UInt64,
        scrollbackLines: Int = TerminalController.mobileReplayScrollbackLineBudget,
        scrollForwardLines: Int = 0
    ) -> MobileTerminalRenderGridFrame? {
        guard surfaceID == terminalPanel.id else { return nil }
        guard let frame = terminalPanel.surface.mobileRenderGridFrame(
            stateSeq: seq,
            scrollbackLines: scrollbackLines,
            scrollForwardLines: scrollForwardLines
        )?.frame else {
            return nil
        }
        return stampMobileRenderGridFrame(frame, surfaceID: surfaceID)
    }

    func stampMobileRenderGridFrame(
        _ frame: MobileTerminalRenderGridFrame,
        surfaceID: UUID
    ) -> MobileTerminalRenderGridFrame {
        var stamped = frame
        stamped.renderRevision = advanceMobileRenderRevision(surfaceID: surfaceID)
        return stamped
    }

    func advanceMobileRenderRevision(surfaceID: UUID) -> UInt64 {
        var revision = (mobileRenderRevisionsBySurfaceID[surfaceID] ?? 0) &+ 1
        if revision == 0 { revision = 1 }
        mobileRenderRevisionsBySurfaceID[surfaceID] = revision
        return revision
    }

    func mobileTerminalScrollResponsePayload(
        workspaceID: UUID,
        terminalPanel: TerminalPanel,
        surfaceID: UUID,
        params: [String: Any]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "accepted": true,
        ]
        if let interactionEpoch = v2Int(params, "interaction_epoch"), interactionEpoch >= 0 {
            payload["interaction_epoch"] = interactionEpoch
        }
        if let clientRevision = v2Int(params, "client_scroll_revision"), clientRevision >= 0 {
            payload["client_scroll_revision"] = clientRevision
        }
        let window = mobileScrollPrefetchWindow(params: params)
        guard window.before > 0 || window.after > 0 else {
            payload["render_revision"] = advanceMobileRenderRevision(surfaceID: surfaceID)
            return payload
        }
        let stateSeq = MobileTerminalByteTee.shared.currentSequence(surfaceID: surfaceID) ?? 0
        guard let renderGrid = mobileTerminalRenderGridFrame(
            terminalPanel: terminalPanel,
            surfaceID: surfaceID,
            seq: stateSeq,
            scrollbackLines: window.before,
            scrollForwardLines: window.after
        ) else {
            payload["render_revision"] = advanceMobileRenderRevision(surfaceID: surfaceID)
            return payload
        }
        if let renderRevision = renderGrid.renderRevision {
            payload["render_revision"] = renderRevision
        }
        guard renderGrid.activeScreen == .primary,
              let renderGridObject = try? renderGrid.jsonObject() else { return payload }
        payload["columns"] = renderGrid.columns
        payload["rows"] = renderGrid.rows
        payload["render_grid"] = renderGridObject
        payload["seq"] = renderGrid.stateSeq
        return payload
    }

    func mobileScrollPrefetchWindow(
        params: [String: Any],
        defaultBeforeRows: Int = 0,
        defaultAfterRows: Int = 0
    ) -> (before: Int, after: Int) {
        let legacyRows = (params["max_scrollback_rows"] as? NSNumber)?.intValue
        let requestedBefore = (params["prefetch_before_rows"] as? NSNumber)?.intValue
            ?? legacyRows
            ?? defaultBeforeRows
        let requestedAfter = (params["prefetch_after_rows"] as? NSNumber)?.intValue
            ?? defaultAfterRows
        return (
            before: min(max(0, requestedBefore), Self.mobileScrollPrefetchScrollbackLineBudget),
            after: min(max(0, requestedAfter), Self.mobileScrollPrefetchScrollbackLineBudget)
        )
    }

    func mobileScrollDirectionalRuns(params: [String: Any]) -> [MobileTerminalScrollRun]? {
        guard let rawRuns = params["delta_runs"] else {
            let lines = (params["delta_lines"] as? NSNumber)?.doubleValue ?? 0
            guard lines.isFinite else { return nil }
            if lines == 0 { return [] }
            return [MobileTerminalScrollRun(
                lines: lines,
                col: (params["col"] as? NSNumber)?.intValue ?? 0,
                row: (params["row"] as? NSNumber)?.intValue ?? 0
            )]
        }
        guard let objects = rawRuns as? [[String: Any]],
              objects.count <= Self.mobileScrollDirectionalRunLimit else {
            return nil
        }
        var runs: [MobileTerminalScrollRun] = []
        runs.reserveCapacity(objects.count)
        for object in objects {
            guard let lines = (object["lines"] as? NSNumber)?.doubleValue,
                  lines.isFinite,
                  let col = (object["col"] as? NSNumber)?.intValue,
                  let row = (object["row"] as? NSNumber)?.intValue else {
                return nil
            }
            guard lines != 0 else { continue }
            runs.append(MobileTerminalScrollRun(lines: lines, col: col, row: row))
        }
        return runs
    }
}
