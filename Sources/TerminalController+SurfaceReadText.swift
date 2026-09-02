import CmuxControlSocket
import CmuxTerminal
import Foundation

/// Terminal text capture and formatting seams used by the local socket read plane.
extension TerminalController {
    nonisolated static let terminalTextReadFailureMessage = String(
        localized: "socket.terminal.readText.failed",
        defaultValue: "Failed to read terminal text"
    )

    struct TerminalTextRawSnapshot: Sendable {
        var viewport: String?
        var screen: String?
        var history: String?
        var active: String?
    }

    struct TerminalTextPayload: Equatable, Sendable {
        let text: String
        let base64: String
    }

    struct TerminalTextPayloadError: Error, Equatable, Sendable {
        let message: String
    }

    nonisolated static func terminalTextPayload(
        from snapshot: TerminalTextRawSnapshot,
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> Result<TerminalTextPayload, TerminalTextPayloadError> {
        let output: String
        if includeScrollback {
            var candidates: [String] = []
            if let screen = snapshot.screen {
                candidates.append(lineLimit.map { Self.tailTerminalLines(screen, maxLines: $0) } ?? screen)
            }
            if snapshot.history != nil || snapshot.active != nil {
                var merged = lineLimit.map {
                    Self.tailTerminalLines(snapshot.history ?? "", maxLines: $0)
                } ?? (snapshot.history ?? "")
                if let active = snapshot.active {
                    if !merged.isEmpty, !merged.hasSuffix("\n"), !active.isEmpty {
                        merged.append("\n")
                    }
                    merged.append(lineLimit.map { Self.tailTerminalLines(active, maxLines: $0) } ?? active)
                }
                candidates.append(lineLimit.map { Self.tailTerminalLines(merged, maxLines: $0) } ?? merged)
            }

            guard let best = candidates.max(by: { lhs, rhs in
                let left = terminalTextCandidateScore(lhs)
                let right = terminalTextCandidateScore(rhs)
                if left.lines != right.lines {
                    return left.lines < right.lines
                }
                return left.bytes < right.bytes
            }) else {
                return .failure(TerminalTextPayloadError(message: Self.terminalTextReadFailureMessage))
            }
            output = best
        } else {
            guard var viewport = snapshot.viewport else {
                return .failure(TerminalTextPayloadError(message: Self.terminalTextReadFailureMessage))
            }
            if let lineLimit {
                viewport = Self.tailTerminalLines(viewport, maxLines: lineLimit)
            }
            output = viewport
        }

        let base64 = output.data(using: .utf8)?.base64EncodedString() ?? ""
        return .success(TerminalTextPayload(text: output, base64: base64))
    }

    nonisolated private static func terminalTextCandidateScore(_ text: String) -> (lines: Int, bytes: Int) {
        if text.isEmpty { return (0, 0) }
        var newlineCount = 0
        var byteCount = 0
        for byte in text.utf8 {
            byteCount += 1
            if byte == 0x0A {
                newlineCount += 1
            }
        }
        return (newlineCount + 1, byteCount)
    }

    /// Sendable raw terminal capture and identity returned by the main actor.
    struct ReadTextCapture: Sendable {
        let rawSnapshot: TerminalTextRawSnapshot
        let workspaceID: UUID
        let surfaceID: UUID
        let windowID: UUID?
        let workspaceRef: String
        let surfaceRef: String
        let windowRef: String?
    }

    /// Typed error produced before a terminal text capture can be formatted.
    struct ReadTextCaptureError: Sendable {
        let code: String
        let message: String
        let data: JSONValue?

        init(code: String, message: String, data: Any? = nil) {
            self.code = code
            self.message = message
            self.data = data.flatMap(JSONValue.init(foundationObject:))
        }

        var controlCallResult: ControlCallResult {
            .err(code: code, message: message, data: data)
        }

        var legacyCallResult: V2CallResult {
            .err(code: code, message: message, data: data?.foundationObject)
        }
    }

    /// Main-actor capture outcome that can cross to a socket worker safely.
    enum ReadTextCaptureOutcome: Sendable {
        /// An error fully resolved on the main actor (its message and `data`
        /// need no off-main formatting), returned as a typed value.
        case finished(ReadTextCaptureError)
        /// The raw Ghostty text and identity; the caller formats it off-main.
        case captured(ReadTextCapture)
    }

    /// Capture outcome plus the parsed text-projection options.
    struct ReadTextCaptureEnvelope: Sendable {
        let outcome: ReadTextCaptureOutcome
        let includeScrollback: Bool
        let lineLimit: Int?
    }

    /// Captures the routing result and raw Ghostty text on the main actor.
    ///
    /// The returned value is Sendable so an async socket caller can perform
    /// line tailing, candidate selection, projection, and base64 encoding on
    /// its worker without parking the main queue.
    func v2SurfaceReadTextCapture(
        params: [String: Any],
        includeScrollback: Bool,
        lineLimit: Int?
    ) -> ReadTextCaptureOutcome {
        // Mint refs for current topology so caller-supplied `kind:N` refs
        // resolve, exactly as the former main-actor dispatch did before
        // handing off to the coordinator.
        v2RefreshKnownRefs()
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: v2HasNonNullParam(params, "window_id"),
            windowID: v2UUID(params, "window_id"),
            groupID: v2UUID(params, "group_id"),
            workspaceID: v2UUID(params, "workspace_id"),
            surfaceID: v2UUID(params, "surface_id")
                ?? v2UUID(params, "terminal_id")
                ?? v2UUID(params, "tab_id"),
            paneID: v2UUID(params, "pane_id")
        )
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .finished(ReadTextCaptureError(
                code: "unavailable",
                message: "TabManager not available"
            ))
        }
        if let lineLimit, lineLimit <= 0 {
            return .finished(ReadTextCaptureError(
                code: "invalid_params",
                message: "lines must be greater than 0"
            ))
        }
        // The former witness resolved the explicit `surface_id` param only
        // (no terminal_id/tab_id aliases) for target selection.
        let explicitSurfaceID = v2UUID(params, "surface_id")
        let hasSurfaceIDParam = params["surface_id"] != nil
        let workspaceID: UUID
        let surfaceId: UUID
        let terminalSurface: TerminalSurface
        // Per-window docks (the former single global dock): the window id
        // resolves from the dock itself in the dock branch, from the routed
        // TabManager otherwise — mirroring the coordinator witnesses' shape.
        let resolvedWindowID: UUID?
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = terminalPanel(
                in: dock,
                explicitSurfaceID: explicitSurfaceID,
                hasSurfaceIDParam: hasSurfaceIDParam,
                routing: routing
            )
            if target.invalidSurfaceID {
                return .finished(ReadTextCaptureError(
                    code: "not_found",
                    message: "Surface not found for the given surface_id"
                ))
            }
            guard let dockSurfaceId = target.surfaceID else {
                return .finished(ReadTextCaptureError(
                    code: "not_found",
                    message: "No focused surface"
                ))
            }
            guard target.terminalPanel != nil else {
                return .finished(ReadTextCaptureError(
                    code: "invalid_params",
                    message: "Surface is not a terminal",
                    data: ["surface_id": dockSurfaceId.uuidString]
                ))
            }
            guard let terminalTarget = dock.controlSocketTerminalTarget(for: dockSurfaceId) else {
                return .finished(ReadTextCaptureError(
                    code: "surface_unavailable",
                    message: Self.terminalSurfaceUnavailableMessage,
                    data: ["surface_id": dockSurfaceId.uuidString]
                ))
            }
            workspaceID = dock.workspaceId
            surfaceId = dockSurfaceId
            terminalSurface = terminalTarget.surface
            resolvedWindowID = dockResultWindowId(for: dock, tabManager: tabManager)
        } else {
            guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
                return .finished(ReadTextCaptureError(
                    code: "not_found",
                    message: "Workspace not found"
                ))
            }
            if hasSurfaceIDParam {
                guard let id = explicitSurfaceID else {
                    return .finished(ReadTextCaptureError(
                        code: "not_found",
                        message: "Surface not found for the given surface_id"
                    ))
                }
                guard ws.controlTerminalTarget(for: id) != nil else {
                    return .finished(ReadTextCaptureError(
                        code: "invalid_params",
                        message: "Surface is not a terminal",
                        data: ["surface_id": id.uuidString]
                    ))
                }
                guard let target = ws.controlSocketTerminalTarget(for: id) else {
                    return .finished(ReadTextCaptureError(
                        code: "surface_unavailable",
                        message: Self.terminalSurfaceUnavailableMessage,
                        data: ["surface_id": id.uuidString]
                    ))
                }
                surfaceId = target.surfaceID
                terminalSurface = target.surface
            } else {
                guard let focused = ws.controlDefaultTerminalTarget(paneID: routing.paneID) else {
                    return .finished(ReadTextCaptureError(
                        code: "not_found",
                        message: "No focused surface"
                    ))
                }
                guard let target = ws.controlSocketTerminalTarget(for: focused) else {
                    return .finished(ReadTextCaptureError(
                        code: "surface_unavailable",
                        message: Self.terminalSurfaceUnavailableMessage,
                        data: ["surface_id": focused.surfaceID.uuidString]
                    ))
                }
                surfaceId = focused.surfaceID
                terminalSurface = target.surface
            }
            workspaceID = ws.id
            resolvedWindowID = v2ResolveWindowId(tabManager: tabManager)
        }
        guard let rawSnapshot = readTerminalTextRawSnapshot(
            terminalSurface: terminalSurface,
            includeScrollback: includeScrollback
        ) else {
            return .finished(ReadTextCaptureError(
                code: "internal_error",
                message: Self.terminalTextReadFailureMessage
            ))
        }
        // `terminalTextPayload`'s only failure predicate is snapshot shape
        // (O(1)), so reject here and mint refs only when a success reply is
        // guaranteed. This preserves the legacy ref ordinal behavior.
        let payloadIsFormattable = includeScrollback
            ? (rawSnapshot.screen != nil || rawSnapshot.history != nil || rawSnapshot.active != nil)
            : rawSnapshot.viewport != nil
        guard payloadIsFormattable else {
            return .finished(ReadTextCaptureError(
                code: "internal_error",
                message: Self.terminalTextReadFailureMessage
            ))
        }
        // Refs mint in the success payload's literal order (workspace,
        // surface, window).
        return .captured(ReadTextCapture(
            rawSnapshot: rawSnapshot,
            workspaceID: workspaceID,
            surfaceID: surfaceId,
            windowID: resolvedWindowID,
            workspaceRef: v2EnsureHandleRef(kind: .workspace, uuid: workspaceID),
            surfaceRef: v2EnsureHandleRef(kind: .surface, uuid: surfaceId),
            windowRef: resolvedWindowID.map {
                v2EnsureHandleRef(kind: .window, uuid: $0)
            }
        ))
    }

    /// `surface.read_text` worker body (issue #5757). The former
    /// `ControlCommandCoordinator.surfaceReadText` ran the whole read — including
    /// full-scrollback line tailing, candidate scoring, and base64 encoding —
    /// on the main actor. Only the routing/Ghostty capture uses one main hop;
    /// formatting remains on the caller's worker.
    nonisolated func v2SurfaceReadText(params: [String: Any]) -> V2CallResult {
        var includeScrollback = v2Bool(params, "scrollback") ?? false
        let lineLimit = v2Int(params, "lines")
        if lineLimit != nil { includeScrollback = true }

        let outcome: ReadTextCaptureOutcome = v2MainSync {
            self.v2SurfaceReadTextCapture(
                params: params,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            )
        }
        switch outcome {
        case let .finished(error):
            return error.legacyCallResult
        case let .captured(capture):
            switch Self.terminalTextPayload(
                from: capture.rawSnapshot,
                includeScrollback: includeScrollback,
                lineLimit: lineLimit
            ) {
            case .success(let payload):
                return .ok([
                    "text": payload.text,
                    "base64": payload.base64,
                    "workspace_id": capture.workspaceID.uuidString,
                    "workspace_ref": capture.workspaceRef,
                    "surface_id": capture.surfaceID.uuidString,
                    "surface_ref": capture.surfaceRef,
                    "window_id": v2OrNull(capture.windowID?.uuidString),
                    "window_ref": v2OrNull(capture.windowRef),
                ])
            case .failure(let error):
                return .err(code: "internal_error", message: error.message, data: nil)
            }
        }
    }
}
