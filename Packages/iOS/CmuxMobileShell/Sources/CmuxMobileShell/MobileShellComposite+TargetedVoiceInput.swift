import CMUXMobileCore
public import CmuxMobileRPC
public import CmuxMobileShellModel
import CmuxMobileSupport
import Foundation

extension MobileShellComposite {
    /// Whether at least one connected Mac can receive GPT Voice input by explicit target.
    public var supportsGPTVoiceMode: Bool {
        workspaces.contains { workspace in
            supportsGPTVoiceTarget(workspaceID: workspace.id)
                && workspace.terminals.contains(where: \.isReady)
        }
    }

    /// Whether the Mac owning a workspace advertised explicit Voice Mode targets.
    public func supportsGPTVoiceTarget(
        workspaceID: MobileWorkspacePreview.ID
    ) -> Bool {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.macConnectionStatus != .unavailable else {
            return false
        }
        let target = workspaceMutationTarget(for: workspaceID)
        if target.isForeground {
            return target.client != nil
                && supportedHostCapabilities.contains(Self.targetedVoiceInputCapability)
        }
        guard let macDeviceID = target.macDeviceID,
              let subscription = secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)],
              subscription.client === target.client else {
            return false
        }
        return subscription.supportedHostCapabilities.contains(
            Self.targetedVoiceInputCapability
        )
    }

    /// Insert exact transcribed speech into one terminal on its owning Mac.
    ///
    /// Unlike focused dictation, this route is explicit and can address a
    /// terminal on a live secondary Mac without changing the foreground Mac.
    public func sendVoiceInput(
        text: String,
        submit: Bool,
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) async throws -> MobileVoiceInputResponse {
        guard !text.isEmpty, text.utf8.count <= 64 * 1_024 else {
            throw MobileShellConnectionError.rpcError(
                "invalid_params",
                L10n.string(
                    "mobile.voiceMode.invalidTranscript",
                    defaultValue: "That transcript cannot be sent."
                )
            )
        }
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              let terminal = workspace.terminals.first(where: { $0.id == terminalID }),
              terminal.isReady,
              supportsGPTVoiceTarget(workspaceID: workspaceID) else {
            throw MobileShellConnectionError.rpcError(
                "target_unavailable",
                L10n.string(
                    "mobile.voiceMode.targetUnavailable",
                    defaultValue: "That terminal is no longer available."
                )
            )
        }

        let target = workspaceMutationTarget(for: workspaceID)
        guard let client = target.client else {
            throw MobileShellConnectionError.connectionClosed
        }
        let foregroundGeneration = connectionGeneration
        var params: [String: Any] = [
            "text": text,
            "submit": submit,
            "client_id": clientID,
            "workspace_id": workspace.rpcWorkspaceID.rawValue,
            "surface_id": terminal.id.rawValue,
        ]
        if let windowID = workspace.windowID, !windowID.isEmpty {
            params["window_id"] = windowID
        }

        let responseData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.voice.input",
                params: params
            )
        )
        if target.isForeground {
            guard isCurrentRemoteOperation(
                client: client,
                generation: foregroundGeneration
            ) else {
                throw MobileShellConnectionError.connectionClosed
            }
        } else {
            guard let macDeviceID = target.macDeviceID,
                  secondaryMacSubscriptions[MacPairingKey(pairingID: macDeviceID)]?.client === client else {
                throw MobileShellConnectionError.connectionClosed
            }
        }
        return try MobileVoiceInputResponse.decode(responseData)
    }
}
