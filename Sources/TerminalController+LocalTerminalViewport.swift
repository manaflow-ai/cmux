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

    /// Handles a set/reset mutation on the main actor for one connection.
    func v2LocalViewportMutationResult(
        request: ControlRequest,
        session: LocalTerminalViewportSession
    ) -> V2CallResult {
        let params = request.params.mapValues(\.foundationObject)
        switch request.method {
        case "terminal.viewport.set", "mobile.terminal.viewport.set":
            return v2LocalTerminalViewportSet(params: params, session: session)
        case "terminal.viewport.reset", "mobile.terminal.viewport.reset":
            return v2LocalTerminalViewportReset(params: params, session: session)
        default:
            return .err(
                code: "method_not_found",
                message: Self.localViewportUnknownMethodMessage,
                data: nil
            )
        }
    }

    /// Executes a connection-local viewport command without doing render-grid
    /// projection on the main actor. Target capture remains a minimal
    /// `MainActor` operation; response parsing, frame projection, and JSON
    /// encoding run on the socket worker.
    nonisolated func v2LocalViewportCommandResultAsync(
        request: ControlRequest,
        session: LocalTerminalViewportSession
    ) async -> String {
        switch request.method {
        case "terminal.viewport.set", "mobile.terminal.viewport.set",
             "terminal.viewport.reset", "mobile.terminal.viewport.reset":
            let response = await v2MainAsync {
                self.v2Result(
                    id: request.id?.foundationObject,
                    self.v2LocalViewportMutationResult(
                        request: request,
                        session: session
                    )
                )
            }
            return response
        case "terminal.replay", "mobile.terminal.replay":
            guard !(await session.isEmpty) else {
                let params = request.params.mapValues(\.foundationObject)
                return await v2MainAsync {
                    self.v2Result(
                        id: request.id?.foundationObject,
                        self.v2MobileTerminalReplay(params: params)
                    )
                }
            }
            let captured = await v2MainAsync {
                let params = request.params.mapValues(\.foundationObject)
                let hasOverride = self.mobileCanonicalTerminalTarget(params: params)
                    .flatMap { session.viewport(for: $0.surfaceID) } != nil
                return (
                    response: self.v2Result(
                        id: request.id?.foundationObject,
                        self.v2MobileTerminalReplay(
                            params: params,
                            adoptReplayBaseline: !hasOverride,
                            recordProducerIdentity: !hasOverride
                        )
                    ),
                    hasOverride: hasOverride
                )
            }
            guard captured.hasOverride else { return captured.response }
            return await projectLocalViewportResponse(captured.response, session: session)
        case "terminal.scroll", "mobile.terminal.scroll":
            guard !(await session.isEmpty) else {
                let params = request.params.mapValues(\.foundationObject)
                return await v2MainAsync {
                    self.v2Result(
                        id: request.id?.foundationObject,
                        self.v2MobileTerminalScroll(params: params)
                    )
                }
            }
            let captured = await v2MainAsync {
                let params = request.params.mapValues(\.foundationObject)
                let hasOverride = self.mobileCanonicalTerminalTarget(params: params)
                    .flatMap { session.viewport(for: $0.surfaceID) } != nil
                return (
                    response: self.v2Result(
                        id: request.id?.foundationObject,
                        self.v2MobileTerminalScroll(
                            params: params,
                            adoptReplayBaseline: !hasOverride,
                            recordProducerIdentity: !hasOverride
                        )
                    ),
                    hasOverride: hasOverride
                )
            }
            guard captured.hasOverride else { return captured.response }
            return await projectLocalViewportResponse(captured.response, session: session)
        default:
            return Self.v2Encoder.error(
                id: request.id,
                code: "method_not_found",
                message: Self.localViewportUnknownMethodMessage
            )
        }
    }

    /// Projects one already-encoded replay/scroll response after resolving the
    /// connection's current surface override. The response is returned intact
    /// when the command failed or the connection has no override for that
    /// surface.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    private nonisolated func projectLocalViewportResponse(
        _ response: String,
        session: LocalTerminalViewportSession
    ) async -> String {
        guard let data = response.data(using: .utf8),
              var envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              envelope["ok"] as? Bool == true,
              var result = envelope["result"] as? [String: Any],
              let rawSurfaceID = result["surface_id"] as? String,
              let surfaceID = UUID(uuidString: rawSurfaceID),
              let viewport = await session.viewport(for: surfaceID) else {
            return response
        }

        let nativeColumns = result["columns"]
        let nativeRows = result["rows"]
        var didProjectRenderGrid = false
        if let object = result["render_grid"],
           let frame = try? MobileTerminalRenderGridFrame.decodeJSONObject(object),
           let projectedObject = try? frame.projectedViewport(
               columns: viewport.columns,
               rows: viewport.rows
           ).jsonObject() {
            result["render_grid"] = projectedObject
            result["columns"] = viewport.columns
            result["rows"] = viewport.rows
            didProjectRenderGrid = true
        }
        result["viewport_override"] = didProjectRenderGrid
        if !didProjectRenderGrid {
            if let nativeColumns { result["columns"] = nativeColumns }
            if let nativeRows { result["rows"] = nativeRows }
            result["projection"] = "native_fallback"
        }
        envelope["result"] = result
        guard let value = JSONValue(foundationObject: envelope) else {
            return response
        }
        return Self.v2Encoder.encode(value)
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
            columns: min(
                max(LocalTerminalViewport.minimumColumns, Int(size.columns)),
                LocalTerminalViewport.maximumColumns
            ),
            rows: min(
                max(LocalTerminalViewport.minimumRows, Int(size.rows)),
                LocalTerminalViewport.maximumRows
            )
        )!
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

    /// Applies a local viewport to the text returned by `surface.read_text`.
    ///
    /// Target resolution and Ghostty capture are performed through one
    /// suspending main-actor hop. Formatting and viewport projection then run
    /// on the socket worker, so a large scrollback read never parks the main
    /// queue behind a synchronous dispatch.
#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func v2SurfaceReadTextForLocalConnection(
        request: ControlRequest,
        session: LocalTerminalViewportSession
    ) async -> String {
        let capture = await v2MainAsync {
            let params = request.params.mapValues(\.foundationObject)
            var includeScrollback = self.v2Bool(params, "scrollback") ?? false
            let lineLimit = self.v2Int(params, "lines")
            if lineLimit != nil { includeScrollback = true }
            return ReadTextCaptureEnvelope(
                outcome: self.v2SurfaceReadTextCapture(
                    params: params,
                    includeScrollback: includeScrollback,
                    lineLimit: lineLimit
                ),
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        }

        switch capture.outcome {
        case let .finished(error):
            return Self.v2Encoder.response(id: request.id, error.controlCallResult)
        case let .captured(rawCapture):
            guard case .success(let textPayload) = Self.terminalTextPayload(
                from: rawCapture.rawSnapshot,
                includeScrollback: capture.includeScrollback,
                lineLimit: capture.lineLimit
            ) else {
                return Self.v2Encoder.error(
                    id: request.id,
                    code: "internal_error",
                    message: "Failed to read terminal text"
                )
            }

            var payload: [String: Any] = [
                "text": textPayload.text,
                "base64": textPayload.base64,
                "workspace_id": rawCapture.workspaceID.uuidString,
                "workspace_ref": rawCapture.workspaceRef,
                "surface_id": rawCapture.surfaceID.uuidString,
                "surface_ref": rawCapture.surfaceRef,
                "window_id": v2OrNull(rawCapture.windowID?.uuidString),
                "window_ref": v2OrNull(rawCapture.windowRef),
            ]
            guard let viewport = await session.viewport(for: rawCapture.surfaceID) else {
                return v2Result(id: request.id?.foundationObject, .ok(payload))
            }
            let projected = textPayload.text.projectedTerminalText(
                columns: viewport.columns,
                rows: viewport.rows,
                keepAllRows: capture.includeScrollback
            )
            payload["text"] = projected
            payload["base64"] = Data(projected.utf8).base64EncodedString()
            payload["viewport_override"] = true
            return v2Result(id: request.id?.foundationObject, .ok(payload))
        }
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

    private static var localViewportUnknownMethodMessage: String {
        String(
            localized: "socket.terminal.viewport.unknownMethod",
            defaultValue: "Unknown terminal viewport method"
        )
    }
}
