import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Routes one live selection read through the panel abstraction. AppKit,
    /// Ghostty, and WebKit stay on the main actor; only the immutable capture
    /// crosses back to the socket worker for payload construction and encoding.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated func v2SurfaceReadSelection(
        params: [String: JSONValue]
    ) async -> V2CallResult {
        let outcome = await captureSurfaceSelection(params: params)
        switch outcome {
        case .failed(let failure):
            return .err(
                code: failure.code,
                message: failure.message,
                data: failure.data
            )
        case .captured(let capture):
            let selection = capture.snapshot
            var payload: [String: Any] = [
                "has_selection": selection.hasSelection,
                "kind": selection.kind.rawValue,
                "text": selection.text,
                "base64": Data(selection.text.utf8).base64EncodedString(),
                "workspace_id": capture.workspaceID.uuidString,
                "workspace_ref": capture.workspaceRef,
                "surface_id": capture.surfaceID.uuidString,
                "surface_ref": capture.surfaceRef,
                "window_id": v2OrNull(capture.windowID?.uuidString),
                "window_ref": v2OrNull(capture.windowRef),
            ]
            if let filePath = selection.filePath {
                payload["file_path"] = filePath
            }
            if let lineRange = selection.lineRange {
                payload["line_range"] = [
                    "start": lineRange.start,
                    "end": lineRange.end,
                ]
            }
            if let url = selection.url {
                payload["url"] = url
            }
            return .ok(payload)
        }
    }

    private func captureSurfaceSelection(
        params typedParams: [String: JSONValue]
    ) async -> SurfaceSelectionSocketCaptureOutcome {
        func failure(
            code: String,
            message: String,
            data: [String: String]? = nil
        ) -> SurfaceSelectionSocketCaptureOutcome {
            .failed(SurfaceSelectionSocketFailure(
                code: code,
                message: message,
                data: data
            ))
        }

        let params = typedParams.mapValues(\.foundationObject)
        let selectorKeys = [
            "window_id",
            "group_id",
            "workspace_id",
            "surface_id",
            "terminal_id",
            "tab_id",
            "pane_id",
        ]
        // UUID selectors are self-contained. Refresh the registry only when a
        // caller supplied an opaque ref that needs resolving; a focused or
        // UUID-routed read should not sweep the entire app topology first.
        let hasUnresolvedOpaqueSelector = selectorKeys.contains { key in
            guard v2HasNonNullParam(params, key),
                  let raw = params[key] as? String else {
                return false
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else {
                return false
            }
            return v2MainSync { v2ResolveHandleRef(trimmed) } == nil
        }
        if hasUnresolvedOpaqueSelector {
            v2RefreshKnownRefs()
        }
        if let invalidSelector = selectorKeys.first(where: {
            v2HasNonNullParam(params, $0) && v2UUID(params, $0) == nil
        }) {
            return failure(
                code: "invalid_params",
                message: String(
                    format: String(
                        localized: "socket.surfaceSelection.invalidSelector",
                        defaultValue: "Invalid selector for `%@`."
                    ),
                    invalidSelector
                ),
                data: ["selector": invalidSelector]
            )
        }
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
            return failure(
                code: "unavailable",
                message: String(
                    localized: "socket.surfaceSelection.tabManagerUnavailable",
                    defaultValue: "Selection reading is currently unavailable."
                )
            )
        }
        if let groupID = routing.groupID,
           !tabManager.workspaceGroups.contains(where: { $0.id == groupID }) {
            return failure(
                code: "not_found",
                message: String(
                    localized: "socket.surfaceSelection.workspaceNotFound",
                    defaultValue: "Workspace not found."
                )
            )
        }

        let surfaceSelectorKeys = ["surface_id", "terminal_id", "tab_id"]
        let hasSurfaceSelector = surfaceSelectorKeys.contains {
            v2HasNonNullParam(params, $0)
        }
        let explicitSurfaceID = routing.surfaceID
        if hasSurfaceSelector, explicitSurfaceID == nil {
            return failure(
                code: "not_found",
                message: String(
                    localized: "socket.surfaceSelection.surfaceNotFound",
                    defaultValue: "Surface not found for the given surface selector."
                )
            )
        }

        let workspaceID: UUID
        let surfaceID: UUID
        let windowID: UUID?
        let panel: any Panel
        if let dock = windowDockForRouting(routing, tabManager: tabManager) {
            let target = resolvedWindowDockSurfaceId(
                explicitSurfaceID: explicitSurfaceID,
                hasSurfaceIDParam: hasSurfaceSelector,
                routing: routing,
                dock: dock
            )
            if target.invalidSurfaceID {
                return failure(
                    code: "not_found",
                    message: String(
                        localized: "socket.surfaceSelection.surfaceNotFound",
                        defaultValue: "Surface not found for the given surface selector."
                    )
                )
            }
            guard let requestedSurfaceID = target.surfaceID else {
                return failure(
                    code: "not_found",
                    message: String(
                        localized: "socket.surfaceSelection.noFocusedSurface",
                        defaultValue: "No surface is focused."
                    )
                )
            }
            guard let requestedPanel = dock.panels[requestedSurfaceID] else {
                return failure(
                    code: "not_found",
                    message: String(
                        localized: "socket.surfaceSelection.surfaceNotFound",
                        defaultValue: "Surface not found for the given surface selector."
                    ),
                    data: ["surface_id": requestedSurfaceID.uuidString]
                )
            }
            workspaceID = dock.workspaceId
            surfaceID = requestedSurfaceID
            windowID = dockResultWindowId(for: dock, tabManager: tabManager)
            panel = requestedPanel
        } else {
            guard let workspace = resolveSurfaceWorkspace(
                routing: routing,
                tabManager: tabManager
            ) else {
                return failure(
                    code: "not_found",
                    message: String(
                        localized: "socket.surfaceSelection.workspaceNotFound",
                        defaultValue: "Workspace not found."
                    )
                )
            }
            guard let resolution = workspace.controlRequestedSurfaceTarget(
                explicitSurfaceID: explicitSurfaceID,
                routedPaneID: routing.paneID
            ) else {
                return failure(
                    code: "not_found",
                    message: String(
                        localized: "socket.surfaceSelection.noFocusedSurface",
                        defaultValue: "No surface is focused."
                    )
                )
            }
            guard let target = resolution.target else {
                return failure(
                    code: "not_found",
                    message: String(
                        localized: "socket.surfaceSelection.surfaceNotFound",
                        defaultValue: "Surface not found for the given surface selector."
                    ),
                    data: ["surface_id": resolution.requestedSurfaceID.uuidString]
                )
            }
            workspaceID = workspace.id
            surfaceID = target.surfaceID
            windowID = v2ResolveWindowId(tabManager: tabManager)
            panel = target.panel
        }

        let snapshot: SurfaceSelectionSnapshot
        switch await panel.readSurfaceSelection() {
        case .snapshot(let value):
            snapshot = value
        case .unsupported:
            return failure(
                code: "not_supported",
                message: String(
                    localized: "socket.surfaceSelection.unsupported",
                    defaultValue: "This surface does not support selection reads."
                ),
                data: [
                    "surface_id": surfaceID.uuidString,
                    "kind": panel.panelType.rawValue,
                ]
            )
        case .unavailable:
            return failure(
                code: "unavailable",
                message: String(
                    localized: "socket.surfaceSelection.unavailable",
                    defaultValue: "Selection reading is currently unavailable."
                ),
                data: [
                    "surface_id": surfaceID.uuidString,
                    "kind": panel.panelType.rawValue,
                ]
            )
        }

        let workspaceRef = v2EnsureHandleRef(kind: .workspace, uuid: workspaceID)
        let surfaceRef = v2EnsureHandleRef(kind: .surface, uuid: surfaceID)
        let windowRef = windowID.map {
            v2EnsureHandleRef(kind: .window, uuid: $0)
        }
        return .captured(SurfaceSelectionSocketCapture(
            snapshot: snapshot,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            windowID: windowID,
            workspaceRef: workspaceRef,
            surfaceRef: surfaceRef,
            windowRef: windowRef
        ))
    }
}
