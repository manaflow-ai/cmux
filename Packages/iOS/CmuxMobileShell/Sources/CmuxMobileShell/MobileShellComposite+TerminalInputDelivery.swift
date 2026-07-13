import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation

extension MobileShellComposite {
    func performTerminalInput(
        _ input: TerminalInputIntent,
        surfaceID: String,
        interactionEpoch: UInt64
    ) async -> Bool {
        guard let client = remoteClient else { return false }
        let clientIdentity = ObjectIdentifier(client)
        terminalInputRequestCountsByClientID[clientIdentity, default: 0] += 1
        defer { terminalInputRequestDidComplete(client: client) }
        let generation = connectionGeneration
        let workspaceID = MobileWorkspacePreview.ID(rawValue: input.workspaceID)
        let terminalID = MobileTerminalPreview.ID(rawValue: surfaceID)
        let remoteWorkspaceID = remoteWorkspaceID(for: workspaceID)
        var params: [String: Any] = [
            "workspace_id": remoteWorkspaceID.rawValue,
            "surface_id": surfaceID,
            "client_id": clientID,
            "interaction_epoch": Int(clamping: interactionEpoch),
        ]
        let method: String
        switch input {
        case .text(let text, _):
            method = "terminal.input"
            params["text"] = text
            appendTerminalInputViewport(
                to: &params,
                workspaceID: workspaceID,
                terminalID: terminalID
            )
        case .paste(let text, let submitKey, _):
            method = "terminal.paste"
            params["text"] = text
            params["submit_key"] = submitKey
            appendTerminalInputViewport(
                to: &params,
                workspaceID: workspaceID,
                terminalID: terminalID
            )
        case .image(let data, let format, _):
            method = "terminal.paste_image"
            params["image_base64"] = data.base64EncodedString()
            params["image_format"] = format
        case .fence:
            return true
        }

        do {
            let responseData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: method, params: params),
                timeoutNanoseconds: TerminalRPCDeadlinePolicy.input.timeoutNanoseconds
            )
            if isCurrentRemoteOperation(client: client, generation: generation) {
                handleTerminalInputResponse(responseData, surfaceID: surfaceID)
            }
            return true
        } catch {
            guard generation == connectionGeneration else { return false }
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return false }
            markMacConnectionUnavailableIfNeeded(after: error)
            applyOperationalError(error)
            return false
        }
    }

    private func terminalInputRequestDidComplete(client: MobileCoreRPCClient) {
        let clientID = ObjectIdentifier(client)
        let remaining = max(0, terminalInputRequestCountsByClientID[clientID, default: 1] - 1)
        if remaining > 0 {
            terminalInputRequestCountsByClientID[clientID] = remaining
            return
        }
        terminalInputRequestCountsByClientID.removeValue(forKey: clientID)
        guard let retiredClient = terminalInputClientsAwaitingDisconnectByID.removeValue(
            forKey: clientID
        ) else { return }
        Task { await retiredClient.disconnect() }
    }

    private func appendTerminalInputViewport(
        to params: inout [String: Any],
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        guard let viewportSize = reportedViewportSizesByTerminalKey[key] else { return }
        params["viewport_columns"] = viewportSize.columns
        params["viewport_rows"] = viewportSize.rows
        if let generation = viewportReportGenerationsBySurfaceID[terminalID.rawValue] {
            params["viewport_generation"] = Int(clamping: generation)
        }
    }
}

private extension TerminalInputIntent {
    var workspaceID: String {
        switch self {
        case .text(_, let workspaceID),
             .paste(_, _, let workspaceID),
             .image(_, _, let workspaceID):
            workspaceID
        case .fence:
            ""
        }
    }
}
