import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Describes command delivery in a workspace-create result without
    /// exposing the command text itself.
    nonisolated func workspaceCreateCommandDeliveryMetadata(
        requested: Bool,
        error: V2CallResult?
    ) -> [String: Any]? {
        guard requested else { return nil }
        guard let error else { return ["accepted": true] }
        switch error {
        case let .err(code, message, data):
            var errorPayload: [String: Any] = [
                "code": code,
                "message": message,
            ]
            if let data {
                errorPayload["data"] = data
            }
            return [
                "accepted": false,
                "error": errorPayload,
            ]
        case .ok:
            return ["accepted": true]
        }
    }

    /// Journals a command-delivery failure after the workspace itself has been
    /// committed, so callers can distinguish the durable create from the
    /// secondary terminal-input outcome.
    func publishWorkspaceCreateCommandFailure(
        _ result: V2CallResult,
        workspaceID: UUID,
        surfaceID: UUID?,
        windowID: UUID?
    ) {
        guard case let .err(code, message, data) = result else { return }
        var errorPayload: [String: Any] = [
            "code": code,
            "message": message,
        ]
        if let data {
            errorPayload["data"] = data
        }
        CmuxEventBus.shared.publish(
            name: "workspace.command_delivery_failed",
            category: "workspace",
            source: "workspace.create",
            workspaceId: workspaceID.uuidString,
            windowId: windowID?.uuidString,
            payload: [
                "workspace_id": workspaceID.uuidString,
                "surface_id": surfaceID?.uuidString ?? NSNull(),
                "error": errorPayload,
            ]
        )
    }

    /// Sends a CLI-style workspace command through the same surface input path
    /// used by `surface.send_text`. A cold terminal queues the ordered input;
    /// the terminal lifecycle flushes it on the real runtime-ready callback.
    @MainActor
    func sendWorkspaceCreateCommand(
        _ command: String,
        to workspace: Workspace,
        in tabManager: TabManager
    ) -> V2CallResult? {
        guard let panel = workspace.focusedTerminalPanel else {
            return .err(
                code: "surface_unavailable",
                message: Self.terminalSurfaceUnavailableMessage,
                data: ["workspace_id": workspace.id.uuidString]
            )
        }
        // Match the CLI's `--command` text grammar: backslash controls are
        // decoded before a final Enter is added when the command does not
        // already contain one.
        let decoded = command
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
        let input = decoded.hasSuffix("\r") ? decoded : decoded + "\r"
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: workspace.id,
            surfaceID: panel.id,
            paneID: nil
        )
        let resolution = controlSurfaceSendText(
            routing: routing,
            surfaceID: panel.id,
            hasSurfaceIDParam: true,
            text: input,
            resolvedTabManager: tabManager
        )
        let workspaceStrings = controlWorkspaceStrings()
        let surfaceStrings = controlSurfaceRespawnStrings()
        switch resolution {
        case let .sent(windowID, workspaceID, surfaceID, queued):
            let workspaceRef = v2Ref(kind: .workspace, uuid: workspaceID)
            let surfaceRef = v2Ref(kind: .surface, uuid: surfaceID)
            let windowRef = v2Ref(kind: .window, uuid: windowID)
            CmuxEventBus.shared.publish(
                name: "surface.input_sent",
                category: "surface",
                source: "workspace.create",
                workspaceId: workspaceID.uuidString,
                surfaceId: surfaceID.uuidString,
                windowId: windowID?.uuidString,
                payload: [
                    "method": "surface.send_text",
                    "params": [
                        "workspace_id": workspaceID.uuidString,
                        "surface_id": surfaceID.uuidString,
                        "text": NSNull(),
                        "text_length": input.count,
                        "redacted_fields": ["text"],
                    ],
                    "result": [
                        "window_id": v2OrNull(windowID?.uuidString),
                        "window_ref": windowRef,
                        "workspace_id": workspaceID.uuidString,
                        "workspace_ref": workspaceRef,
                        "surface_id": surfaceID.uuidString,
                        "surface_ref": surfaceRef,
                        "queued": queued,
                    ],
                ]
            )
            return nil
        case .tabManagerUnavailable:
            return .err(code: "unavailable", message: workspaceStrings.reorderManyTabManagerUnavailable, data: nil)
        case .workspaceNotFound:
            return .err(code: "not_found", message: workspaceStrings.reorderManyWorkspaceNotFound, data: nil)
        case .surfaceNotFoundForID, .noFocusedSurface:
            return .err(code: "not_found", message: controlSurfaceNotFoundMessage(), data: nil)
        case .unknownKey:
            return .err(
                code: "invalid_params",
                message: String(
                    localized: "socket.terminal.unknownKey",
                    defaultValue: "Unknown key"
                ),
                data: nil
            )
        case let .surfaceNotTerminal(surfaceID):
            return .err(
                code: "invalid_params",
                message: surfaceStrings.surfaceNotTerminal,
                data: ["surface_id": surfaceID.uuidString]
            )
        case let .inputQueueFull(surfaceID):
            return .err(
                code: "input_queue_full",
                message: Self.terminalInputQueueFullMessage,
                data: ["surface_id": surfaceID.uuidString]
            )
        case let .surfaceUnavailable(surfaceID):
            return .err(
                code: "surface_unavailable",
                message: Self.terminalSurfaceUnavailableMessage,
                data: ["surface_id": surfaceID.uuidString]
            )
        case let .processExited(surfaceID):
            return .err(
                code: "process_exited",
                message: Self.terminalProcessExitedMessage,
                data: ["surface_id": surfaceID.uuidString]
            )
        }
    }
}
