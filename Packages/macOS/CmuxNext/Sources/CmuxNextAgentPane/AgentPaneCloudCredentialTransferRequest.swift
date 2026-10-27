import Foundation

/// A real click asks the App to transfer its signed-in provider credential to this exact Cloud
/// chat's machine. The App revalidates all three values against the pane and current account.
public nonisolated struct AgentPaneCloudCredentialTransferRequest: Equatable, Sendable {
    public enum Provider: String, Sendable { case claude, codex }
    public let provider: Provider
    public let machineID: String
    public let sessionID: String

    public static let method = "chat.cloudCredentialTransfer"

    @MainActor init?(params: [String: Any]?) {
        guard let params, Set(params.keys) == ["provider", "machineID", "sessionId"],
              let raw = params["provider"] as? String, let provider = Provider(rawValue: raw),
              let machineID = AgentPaneCloudMachineRequest.machineID(params["machineID"]),
              let sessionID = params["sessionId"] as? String, AgentPaneProcessViewer.isToken(sessionID)
        else { return nil }
        self.provider = provider
        self.machineID = machineID
        self.sessionID = sessionID
    }
}
