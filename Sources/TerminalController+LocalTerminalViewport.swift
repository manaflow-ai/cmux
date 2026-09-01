import CMUXMobileCore
import CmuxControlSocket
import CmuxTerminal
import Foundation
import GhosttyKit

/// Local-socket terminal viewport commands and their connection-local
/// render/read projection. The session never calls a PTY resize API.
@MainActor
extension TerminalController {
    nonisolated static let localViewportCommandMethods: Set<String> = [
        "terminal.viewport.set",
        "terminal.viewport.reset",
        "mobile.terminal.viewport.set",
        "mobile.terminal.viewport.reset",
        "terminal.replay",
        "mobile.terminal.replay",
        "terminal.scroll",
        "mobile.terminal.scroll",
    ]

    /// Dispatches a local-socket viewport command or replay through the same
    /// main-actor target resolution as the mobile terminal API.
    func v2LocalViewportCommandResult(
        request: ControlRequest,
        session: LocalTerminalViewportSession
    ) -> V2CallResult {
        let params = request.params.mapValues(\.foundationObject)
        switch request.method {
        case "terminal.viewport.set", "mobile.terminal.viewport.set":
            return v2LocalTerminalViewportSet(params: params, session: session)
        case "terminal.viewport.reset", "mobile.terminal.viewport.reset":
            return v2LocalTerminalViewportReset(params: params, session: session)
        case "terminal.replay", "mobile.terminal.replay":
            return v2LocalTerminalReplay(params: params, session: session)
        case "terminal.scroll", "mobile.terminal.scroll":
            return v2LocalTerminalScroll(params: params, session: session)
        default:
            return .err(
                code: "method_not_found",
                message: "Unknown method",
                data: nil
            )
        }
    }

    /// Applies a validated per-connection cell or pixel viewport.
    private func v2LocalTerminalViewportSet(
        params: [String: Any],
        session: LocalTerminalViewportSession
    ) -> V2CallResult {
        if v2Bool(params, "reset") == true || v2String(params, "mode") == "native" {
            return v2LocalTerminalViewportReset(params: params, session: session)
        }
        guard let target = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: Self.localViewportSurfaceNotFoundMessage, data: nil)
        }
        guard let viewport = localTerminalViewport(
            params: params,
            target: target.target
        ) else {
            return .err(
                code: "invalid_params",
                message: Self.localViewportDimensionsMessage,
                data: [
                    "columns_min": LocalTerminalViewport.minimumColumns,
                    "columns_max": LocalTerminalViewport.maximumColumns,
                    "rows_min": LocalTerminalViewport.minimumRows,
                    "rows_max": LocalTerminalViewport.maximumRows,
                ]
            )
        }
        session.set(viewport, for: target.surfaceID)
        return localViewportPayload(
            workspaceID: target.workspace.id,
            surfaceID: target.surfaceID,
            viewport: viewport,
            overridden: true
        )
    }

    /// Restores one surface to its native projection for this connection.
    private func v2LocalTerminalViewportReset(
        params: [String: Any],
        session: LocalTerminalViewportSession
    ) -> V2CallResult {
        guard let target = mobileCanonicalTerminalTarget(params: params) else {
            return .err(code: "not_found", message: Self.localViewportSurfaceNotFoundMessage, data: nil)
        }
        _ = session.reset(surfaceID: target.surfaceID)
        guard let surface = target.target.surface.liveSurfaceForGhosttyAccess(
            reason: "localTerminalViewportReset"
        ) else {
            return .err(
                code: "surface_unavailable",
                message: Self.terminalSurfaceUnavailableMessage,
                data: ["surface_id": target.surfaceID.uuidString]
            )
        }
        let size = ghostty_surface_size(surface)
        let viewport = LocalTerminalViewport(
            columns: max(1, Int(size.columns)),
            rows: max(1, Int(size.rows))
        ) ?? LocalTerminalViewport(columns: 1, rows: 1)!
        return localViewportPayload(
            workspaceID: target.workspace.id,
            surfaceID: target.surfaceID,
            viewport: viewport,
            overridden: false
        )
    }

    private func localViewportPayload(
        workspaceID: UUID,
        surfaceID: UUID,
        viewport: LocalTerminalViewport,
        overridden: Bool
    ) -> V2CallResult {
        .ok([
            "workspace_id": workspaceID.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
            "surface_id": surfaceID.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceID),
            "mode": overridden ? "override" : "native",
            "columns": viewport.columns,
            "rows": viewport.rows,
            "override": overridden,
            "pane_resized": false,
            "pty_resized": false,
            "projection": "render_grid",
        ])
    }

    private func localTerminalViewport(
        params: [String: Any],
        target: ControlTerminalSocketTarget
    ) -> LocalTerminalViewport? {
        let hasColumns = v2HasNonNullParam(params, "columns")
        let hasCols = v2HasNonNullParam(params, "cols")
        let hasRows = v2HasNonNullParam(params, "rows")
        let hasWidth = v2HasNonNullParam(params, "width")
        let hasHeight = v2HasNonNullParam(params, "height")
        let hasCellDimensions = hasColumns || hasCols || hasRows
        let hasPixelDimensions = hasWidth || hasHeight
        guard !(hasCellDimensions && hasPixelDimensions),
              !(hasColumns && hasCols),
              !hasCellDimensions || (hasColumns || hasCols) && hasRows,
              !hasPixelDimensions || hasWidth && hasHeight else {
            return nil
        }
        let columnValue = v2StrictInt(params, "columns") ?? v2StrictInt(params, "cols")
        let rowValue = v2StrictInt(params, "rows")
        if hasCellDimensions, let columnValue, let rowValue {
            return LocalTerminalViewport(columns: columnValue, rows: rowValue)
        }
        guard hasPixelDimensions else { return nil }
        guard let width = v2StrictInt(params, "width"),
              let height = v2StrictInt(params, "height"),
              width > 0,
              height > 0,
              let surface = target.surface.liveSurfaceForGhosttyAccess(
                  reason: "localTerminalViewportPixels"
              ) else {
            return nil
        }
        let size = ghostty_surface_size(surface)
        let cellWidth = max(1, Int(size.cell_width_px))
        let cellHeight = max(1, Int(size.cell_height_px))
        return LocalTerminalViewport(
            columns: max(1, width / cellWidth),
            rows: max(1, height / cellHeight)
        )
    }

    private func v2LocalTerminalReplay(
        params: [String: Any],
        session: LocalTerminalViewportSession
    ) -> V2CallResult {
        let result = v2MobileTerminalReplay(
            params: params,
            adoptReplayBaseline: false,
            recordProducerIdentity: false
        )
        guard case .ok(let rawPayload) = result,
              var payload = rawPayload as? [String: Any],
              let rawSurfaceID = payload["surface_id"] as? String,
              let surfaceID = UUID(uuidString: rawSurfaceID),
              let viewport = session.viewport(for: surfaceID) else {
            return result
        }
        payload["columns"] = viewport.columns
        payload["rows"] = viewport.rows
        payload["viewport_override"] = true

        if let object = payload["render_grid"],
           let frame = try? MobileTerminalRenderGridFrame.decodeJSONObject(object) {
            let projected = frame.projectedViewport(
                columns: viewport.columns,
                rows: viewport.rows
            )
            if let projectedObject = try? projected.jsonObject() {
                payload["render_grid"] = projectedObject
            }
        } else if let snapshotEncoded = payload["snapshot_data_b64"] as? String,
                  let data = Data(base64Encoded: snapshotEncoded),
                  let text = String(data: data, encoding: .utf8) {
            let projected = text.projectedTerminalText(
                columns: viewport.columns,
                rows: viewport.rows,
                keepAllRows: false
            )
            payload["snapshot_data_b64"] = Data(projected.utf8).base64EncodedString()
        } else if let dataEncoded = payload["data_b64"] as? String,
                  let data = Data(base64Encoded: dataEncoded),
                  let text = String(data: data, encoding: .utf8) {
            let projected = text.projectedTerminalText(
                columns: viewport.columns,
                rows: viewport.rows,
                keepAllRows: false
            )
            payload["data_b64"] = Data(projected.utf8).base64EncodedString()
        }
        return .ok(payload)
    }

    private func v2LocalTerminalScroll(
        params: [String: Any],
        session: LocalTerminalViewportSession
    ) -> V2CallResult {
        let result = v2MobileTerminalScroll(
            params: params,
            adoptReplayBaseline: false,
            recordProducerIdentity: false
        )
        guard case .ok(let rawPayload) = result,
              var payload = rawPayload as? [String: Any],
              let rawSurfaceID = payload["surface_id"] as? String,
              let surfaceID = UUID(uuidString: rawSurfaceID),
              let viewport = session.viewport(for: surfaceID) else {
            return result
        }
        payload["columns"] = viewport.columns
        payload["rows"] = viewport.rows
        payload["viewport_override"] = true
        if let object = payload["render_grid"],
           let frame = try? MobileTerminalRenderGridFrame.decodeJSONObject(object),
           let projectedObject = try? frame.projectedViewport(
               columns: viewport.columns,
               rows: viewport.rows
           ).jsonObject() {
            payload["render_grid"] = projectedObject
        }
        return .ok(payload)
    }

    /// Applies a local viewport to the text returned by `surface.read_text`.
    /// The canonical capture and expensive text formatting stay on the socket
    /// worker; only the session lookup hops to the main actor after the result
    /// has been formatted.
    nonisolated func v2SurfaceReadTextForLocalConnection(
        request: ControlRequest,
        session: LocalTerminalViewportSession
    ) async -> String {
        let params = request.params.mapValues(\.foundationObject)
        let result = v2SurfaceReadText(params: params)
        guard case .ok(let rawPayload) = result,
              var payload = rawPayload as? [String: Any],
              let rawSurfaceID = payload["surface_id"] as? String,
              let surfaceID = UUID(uuidString: rawSurfaceID),
              let text = payload["text"] as? String else {
            return v2Result(id: request.id?.foundationObject, result)
        }
        guard let viewport = await session.viewport(for: surfaceID) else {
            return v2Result(id: request.id?.foundationObject, result)
        }
        let includeScrollback = v2Bool(params, "scrollback") == true
            || v2Int(params, "lines") != nil
        let projected = text.projectedTerminalText(
            columns: viewport.columns,
            rows: viewport.rows,
            keepAllRows: includeScrollback
        )
        payload["text"] = projected
        payload["base64"] = Data(projected.utf8).base64EncodedString()
        payload["viewport_override"] = true
        return v2Result(id: request.id?.foundationObject, .ok(payload))
    }

    private static var localViewportDimensionsMessage: String {
        String(
            localized: "socket.terminal.viewport.invalidDimensions",
            defaultValue: "Provide positive columns and rows, or positive width and height in pixels."
        )
    }

    private static var localViewportSurfaceNotFoundMessage: String {
        String(
            localized: "socket.terminal.viewport.surfaceNotFound",
            defaultValue: "Terminal surface not found"
        )
    }
}
