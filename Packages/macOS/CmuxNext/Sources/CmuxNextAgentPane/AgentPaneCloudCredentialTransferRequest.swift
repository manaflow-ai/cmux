import Foundation

/// A real click asks the App to transfer its signed-in provider credential to this exact Cloud
/// chat's machine. The App revalidates all three values against the pane and current account.
public nonisolated struct AgentPaneCloudCredentialTransferRequest: Equatable, Sendable {
    public enum Provider: String, Sendable, Equatable {
        case claude, codex

        /// Match the web agentKey convention for named harness profiles, including scoped IDs.
        public init?(harnessID: String?) {
            guard let name = harnessID?.split(separator: "/", omittingEmptySubsequences: false).last,
                  let family = name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace }).first
            else { return nil }
            self.init(rawValue: family.lowercased())
        }
    }
    public let provider: Provider
    public let machineID: String
    public let sessionID: String
    public let retryPromptID: String
    /// Automatic recovery uses only a cached local login and never presents setup UI.
    public let automatic: Bool

    public static let method = "chat.cloudCredentialTransfer"

    @MainActor init?(params: [String: Any]?) {
        guard let params,
              Set(params.keys).isSubset(of: ["provider", "machineID", "sessionId", "retryPromptId", "automatic"]),
              Set(["provider", "machineID", "sessionId", "retryPromptId"]).isSubset(of: params.keys),
              let raw = params["provider"] as? String, let provider = Provider(rawValue: raw),
              let machineID = AgentPaneCloudMachineRequest.machineID(params["machineID"]),
              let sessionID = params["sessionId"] as? String, AgentPaneProcessViewer.isToken(sessionID),
              let retryPromptID = params["retryPromptId"] as? String, AgentPaneProcessViewer.isToken(retryPromptID),
              let automatic = params["automatic"] as? Bool ?? (params["automatic"] == nil ? false : nil)
        else { return nil }
        self.provider = provider
        self.machineID = machineID
        self.sessionID = sessionID
        self.retryPromptID = retryPromptID
        self.automatic = automatic
    }
}
