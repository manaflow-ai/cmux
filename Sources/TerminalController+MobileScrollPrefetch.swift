import CMUXMobileCore
import Foundation

extension TerminalController {
    /// Scrollback rows included in a cold-attach render-grid replay snapshot.
    /// Live render-grid events carry no scrollback; the phone keeps its own
    /// bounded Ghostty scrollback mirror and scrolls that mirror locally while
    /// the Mac remains authoritative.
    nonisolated static let mobileReplayScrollbackLineBudget = 240

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
    ) -> [String: Any]? {
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
        ) else { return nil }
        if let renderRevision = renderGrid.renderRevision {
            payload["render_revision"] = renderRevision
        }
        guard renderGrid.activeScreen == .primary else { return payload }
        guard let renderGridObject = try? renderGrid.jsonObject() else { return nil }
        payload["columns"] = renderGrid.columns
        payload["rows"] = renderGrid.rows
        payload["render_grid"] = renderGridObject
        payload["seq"] = renderGrid.stateSeq
        return payload
    }

    func mobileTerminalScrollRejectedPayload(
        workspaceID: UUID,
        surfaceID: UUID,
        params: [String: Any]
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "workspace_id": workspaceID.uuidString,
            "surface_id": surfaceID.uuidString,
            "accepted": false,
        ]
        if let epoch = v2Int(params, "interaction_epoch") {
            payload["interaction_epoch"] = epoch
        }
        if let revision = v2Int(params, "client_scroll_revision") {
            payload["client_scroll_revision"] = revision
        }
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
        let directionLines = (params["delta_runs"] as? [[String: Any]])?
            .reversed()
            .compactMap { object -> Double? in
                if let rows = (object["primary_rows"] as? NSNumber)?.intValue,
                   rows != 0 {
                    return Double(rows)
                }
                return (object["lines"] as? NSNumber)?.doubleValue
            }
            .first(where: { $0.isFinite && $0 != 0 })
            ?? (params["primary_rows"] as? NSNumber).map { Double($0.intValue) }
            ?? (params["delta_lines"] as? NSNumber)?.doubleValue
        let bounded = MobileTerminalScrollPrefetchWindow.bounded(
            requestedBeforeRows: requestedBefore,
            requestedAfterRows: requestedAfter,
            directionLines: directionLines
        )
        return (
            before: bounded.rowsBeforeViewport,
            after: bounded.rowsAfterViewport
        )
    }

    func mobileScrollDirectionalRuns(params: [String: Any]) -> [MobileTerminalScrollRun]? {
        guard let rawRuns = params["delta_runs"] else {
            let lines = (params["delta_lines"] as? NSNumber)?.doubleValue ?? 0
            let primaryRows = (params["primary_rows"] as? NSNumber)?.intValue
            guard lines.isFinite else { return nil }
            let run = primaryRows.map {
                MobileTerminalScrollRun(
                    primaryRows: $0,
                    alternateScreenLines: lines,
                    col: (params["col"] as? NSNumber)?.intValue ?? 0,
                    row: (params["row"] as? NSNumber)?.intValue ?? 0
                )
            } ?? MobileTerminalScrollRun(
                lines: lines,
                col: (params["col"] as? NSNumber)?.intValue ?? 0,
                row: (params["row"] as? NSNumber)?.intValue ?? 0
            )
            return run.hasEffect ? [run] : []
        }
        guard let objects = rawRuns as? [[String: Any]],
              objects.count <= MobileTerminalScrollRun.maximumOrderedBatchCount else {
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
            let primaryRows = (object["primary_rows"] as? NSNumber)?.intValue
            let run = primaryRows.map {
                MobileTerminalScrollRun(
                    primaryRows: $0,
                    alternateScreenLines: lines,
                    col: col,
                    row: row
                )
            } ?? MobileTerminalScrollRun(lines: lines, col: col, row: row)
            guard run.hasEffect else { continue }
            runs.append(run)
        }
        return runs
    }

    /// Forward a phone scroll gesture to the real surface so libghostty handles
    /// it per-mode (scrollback in the normal screen, mouse-wheel to the program
    /// in the alt screen). The producer already exports the live `vp_top`, so
    /// the resulting viewport mirrors back to the phone; nudge an emit since a
    /// pure scroll with no PTY output may not fire a render/tick on its own.
    func v2MobileTerminalScroll(params: [String: Any]) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        guard recordMobileInteractionEpoch(
            params: params,
            surfaceID: surfaceId,
            rejectOlder: true
        ) else {
            return .ok(mobileTerminalScrollRejectedPayload(
                workspaceID: resolved.workspace.id,
                surfaceID: surfaceId,
                params: params
            ))
        }
        guard let directionalRuns = mobileScrollDirectionalRuns(params: params) else {
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.mobileTerminal.invalidScrollRuns",
                    defaultValue: "Invalid terminal scroll runs"
                ),
                data: nil
            )
        }
        if directionalRuns.isEmpty {
            guard terminalPanel.surface.mobileScroll(
                primaryRows: nil,
                deltaLines: 0,
                col: 0,
                row: 0
            ) else {
                return .ok(mobileTerminalScrollRejectedPayload(
                    workspaceID: resolved.workspace.id,
                    surfaceID: surfaceId,
                    params: params
                ))
            }
        } else {
            for run in directionalRuns {
                guard terminalPanel.surface.mobileScroll(
                    primaryRows: run.primaryRows,
                    deltaLines: run.lines,
                    col: run.col,
                    row: run.row
                ) else {
                    return .ok(mobileTerminalScrollRejectedPayload(
                        workspaceID: resolved.workspace.id,
                        surfaceID: surfaceId,
                        params: params
                    ))
                }
            }
            MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        }
        guard let payload = mobileTerminalScrollResponsePayload(
            workspaceID: resolved.workspace.id,
            terminalPanel: terminalPanel,
            surfaceID: surfaceId,
            params: params
        ) else {
            return .ok(mobileTerminalScrollRejectedPayload(
                workspaceID: resolved.workspace.id,
                surfaceID: surfaceId,
                params: params
            ))
        }
        return .ok(payload)
    }

    func v2MobileTerminalMouse(params: [String: Any]) -> V2CallResult {
        v2MobileTerminalMouse(params: params) { terminalPanel, col, row in
            terminalPanel.surface.mobileClick(col: col, row: row)
        }
    }

    func v2MobileTerminalMouse(
        params: [String: Any],
        applyClick: (TerminalPanel, Int, Int) -> Bool
    ) -> V2CallResult {
        if let error = mobileWorkspaceIDValidationError(params: params) {
            return error
        }
        if let error = mobileTerminalAliasValidationError(params: params) {
            return error
        }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceId = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalPanel(for: surfaceId) else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let col = (params["col"] as? NSNumber)?.intValue ?? 0
        let row = (params["row"] as? NSNumber)?.intValue ?? 0
        guard recordMobileInteractionEpoch(
            params: params,
            surfaceID: surfaceId,
            rejectOlder: true
        ) else {
            return .ok(mobileTerminalScrollRejectedPayload(
                workspaceID: resolved.workspace.id,
                surfaceID: surfaceId,
                params: params
            ))
        }
        guard applyClick(terminalPanel, max(0, col), max(0, row)) else {
            return .err(code: "unavailable", message: "Terminal surface is unavailable", data: nil)
        }
        MobileTerminalRenderObserver.shared.noteTerminalBytes(surfaceID: terminalPanel.id)
        var payload: [String: Any] = [
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "accepted": true,
        ]
        if let epoch = v2Int(params, "interaction_epoch") {
            payload["interaction_epoch"] = epoch
        }
        return .ok(payload)
    }

    /// Records the newest interaction epoch for one client/session/surface.
    /// Input and lifecycle requests advance the fence but are never dropped.
    /// Scroll is rejected when it arrives behind that fence, preventing an old
    /// async gesture RPC from moving the Mac viewport after newer input or recovery.
    func recordMobileInteractionEpoch(
        params: [String: Any],
        surfaceID: UUID,
        rejectOlder: Bool
    ) -> Bool {
        guard let clientID = v2String(params, "client_id"),
              let rawEpoch = v2Int(params, "interaction_epoch"),
              rawEpoch >= 0 else {
            return true
        }
        let sessionID = v2String(params, "interaction_session_id") ?? ""
        guard sessionID.utf8.count <= 128 else { return false }
        let epoch = UInt64(rawEpoch)
        var clients = mobileInteractionEpochsBySurfaceID[surfaceID] ?? [:]
        var sessions = clients[clientID] ?? [:]
        let current = sessions[sessionID] ?? 0
        if sessions[sessionID] == nil {
            let identityCount = clients.values.reduce(0) { $0 + $1.count }
            guard identityCount < 64 else { return false }
        }
        if rejectOlder, epoch < current {
            return false
        }
        if epoch > current {
            sessions[sessionID] = epoch
            clients[clientID] = sessions
            mobileInteractionEpochsBySurfaceID[surfaceID] = clients
        }
        return true
    }

    /// Retire only interaction sessions no longer owned by any live mobile
    /// connection. Viewport ownership remains keyed by installed client ID.
    func clearMobileInteractionEpochs(
        clientSessions: [(clientID: String, sessionID: String)]
    ) {
        guard !clientSessions.isEmpty else { return }
        for surfaceID in Array(mobileInteractionEpochsBySurfaceID.keys) {
            var clients = mobileInteractionEpochsBySurfaceID[surfaceID] ?? [:]
            for identity in clientSessions {
                guard var sessions = clients[identity.clientID] else { continue }
                sessions.removeValue(forKey: identity.sessionID)
                clients[identity.clientID] = sessions.isEmpty ? nil : sessions
            }
            mobileInteractionEpochsBySurfaceID[surfaceID] = clients.isEmpty ? nil : clients
        }
    }

}
