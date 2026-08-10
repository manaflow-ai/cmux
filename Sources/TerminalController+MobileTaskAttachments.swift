import CmuxControlSocket
import CmuxTerminal
import Foundation

extension TerminalController {
    /// Creates the shared-policy attachment store used by every mobile route.
    func mobileTaskAttachmentStore() -> MobileTaskAttachmentStore {
        MobileTaskAttachmentStore(
            rootURL: MobileTaskAttachmentStore.defaultRootURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ),
            now: Date(),
            fileManager: FileManager.default
        )
    }

    /// Handles one `mobile.task.attachment.upload` chunk.
    func v2MobileTaskAttachmentUpload(params: [String: Any]) -> V2CallResult {
        guard let operationIDString = v2RawString(params, "operation_id"),
              let operationID = UUID(uuidString: operationIDString),
              let uploadIDString = v2RawString(params, "upload_id"),
              let uploadID = UUID(uuidString: uploadIDString),
              let fileName = v2RawString(params, "file_name"),
              let totalBytes = v2Int(params, "total_bytes"),
              let offset = v2Int(params, "offset"),
              let dataBase64 = v2RawString(params, "data_b64"),
              let isLast = params["last"] as? Bool else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid attachment upload parameters",
                data: nil
            )
        }
        let store = mobileTaskAttachmentStore()
        do {
            let result = try store.upload(MobileTaskAttachmentUploadRequest(
                operationID: operationID,
                uploadID: uploadID,
                fileName: fileName,
                totalBytes: totalBytes,
                offset: offset,
                dataBase64: dataBase64,
                isLast: isLast
            ))
            var payload: [String: Any] = [
                "received_bytes": result.receivedBytes,
            ]
            if let path = result.path {
                payload["path"] = path
            }
            return .ok(payload)
        } catch let error as MobileTaskAttachmentStoreError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(
                code: "internal_error",
                message: "Could not store task attachment",
                data: nil
            )
        }
    }

    /// Injects a securely resolved completed upload path into one terminal.
    func v2MobileTerminalPasteAttachment(params: [String: Any]) -> V2CallResult {
        guard let operationIDString = v2RawString(params, "operation_id"),
              let operationID = UUID(uuidString: operationIDString),
              let uploadIDString = v2RawString(params, "upload_id"),
              let uploadID = UUID(uuidString: uploadIDString) else {
            return .err(
                code: "invalid_params",
                message: "Missing or invalid staged attachment identity",
                data: nil
            )
        }
        if let error = mobileWorkspaceIDValidationError(params: params) { return error }
        if let error = mobileTerminalAliasValidationError(params: params) { return error }
        guard let resolved = mobileResolveWorkspaceAndSurface(params: params, requireTerminal: true),
              let surfaceID = resolved.surfaceId,
              let terminalPanel = resolved.workspace.terminalInputTarget(forPanelID: surfaceID)?.panel else {
            return .err(code: "not_found", message: "Terminal surface not found", data: nil)
        }
        let store = mobileTaskAttachmentStore()
        let fileURL: URL
        do {
            fileURL = try store.completedAttachmentURL(
                operationID: operationID,
                uploadID: uploadID
            )
        } catch let error as MobileTaskAttachmentStoreError {
            return .err(code: error.code, message: error.message, data: nil)
        } catch {
            return .err(code: "invalid_params", message: "Attachment is unavailable", data: nil)
        }
        _ = applyMobileViewportReport(params: params, terminalPanel: terminalPanel)
        let result = terminalPanel.surface.sendInputResult(fileURL.path.terminalShellEscaped)
        switch result {
        case .sent:
            terminalPanel.surface.forceRefresh(reason: "mobileHost.terminalPasteAttachment")
        case .queued:
            break
        case .inputQueueFull:
            return .err(code: "input_queue_full", message: Self.terminalInputQueueFullMessage, data: nil)
        case .surfaceUnavailable:
            return .err(code: "surface_unavailable", message: Self.terminalSurfaceUnavailableMessage, data: nil)
        case .processExited:
            return .err(code: "process_exited", message: Self.terminalProcessExitedMessage, data: nil)
        }
        return .ok([
            "workspace_id": resolved.workspace.id.uuidString,
            "surface_id": terminalPanel.id.uuidString,
            "queued": result == .queued,
            "file_name": fileURL.lastPathComponent,
        ])
    }
}
