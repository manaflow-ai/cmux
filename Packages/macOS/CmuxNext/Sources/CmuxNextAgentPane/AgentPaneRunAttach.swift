import Foundation

/// A redeemed Run capability passed to the native terminal/session bridge.
/// The route is retained only for validation and diagnostics; enrolled hosts
/// resolve the VM and terminal ids through their existing daemon registry.
public nonisolated struct AgentPaneRunAttach: Equatable, Sendable {
    public let runID: String
    public let attemptID: String
    public let provider: String?
    public let providerVMID: String
    public let providerWorkspaceID: String?
    public let providerTerminalID: String
    public let route: String
    public let session: String
    public let trustedCarrier: Bool
    public let expiresAtUnix: Double

    public init?(params: [String: Any]) {
        guard let runID = params["runId"] as? String, !runID.isEmpty, runID.count <= 256,
              let attemptID = params["attemptId"] as? String, !attemptID.isEmpty, attemptID.count <= 256,
              let providerVMID = params["providerVmId"] as? String, !providerVMID.isEmpty, providerVMID.count <= 256,
              let providerTerminalID = params["providerTerminalId"] as? String, !providerTerminalID.isEmpty, providerTerminalID.count <= 256,
              let route = params["route"] as? String, route.count <= 4096,
              let url = URL(string: route), ["ws", "wss"].contains(url.scheme?.lowercased()), url.host != nil,
              let session = params["session"] as? String, !session.isEmpty, session.count <= 256,
              let trustedCarrier = params["trustedCarrier"] as? Bool, trustedCarrier,
              let expiresAtUnix = (params["expiresAtUnix"] as? NSNumber)?.doubleValue,
              expiresAtUnix > Date().timeIntervalSince1970 else { return nil }
        self.runID = runID
        self.attemptID = attemptID
        self.provider = (params["provider"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(128)) }
        self.providerVMID = providerVMID
        self.providerWorkspaceID = (params["providerWorkspaceId"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(256)) }
        self.providerTerminalID = providerTerminalID
        self.route = route
        self.session = session
        self.trustedCarrier = trustedCarrier
        self.expiresAtUnix = expiresAtUnix
    }
}
