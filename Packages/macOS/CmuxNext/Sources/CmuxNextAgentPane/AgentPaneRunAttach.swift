public import Foundation

/// `run.attach`: a redeemed durable Run attach ticket, passed to the App so it opens the attempt's
/// terminal on the enrolled worker daemon as a remote-terminal tab in this pane.
///
/// The App resolves `providerVMID` and `providerTerminalID` against the Cloud machines it already
/// knows and opens only on a connected one whose session is `session`. Every field is the page's
/// claim: the route, carrier and expiry checks here only refuse a malformed or stale request, they
/// do not verify the ticket. The route is never dialed and no route token is accepted, so no
/// credential reaches the App or a shell. `expiresAtUnix` is in seconds.
public nonisolated struct AgentPaneRunAttach: Equatable, Sendable {
    public let runID: String
    public let attemptID: String
    public let provider: String?
    public let providerVMID: String
    public let providerWorkspaceID: String?
    public let providerTerminalID: String
    public let route: String
    public let session: String
    public let expiresAtUnix: Double

    /// Nil when a field breaks the contract or the endpoint has expired at `now`.
    public init?(params: [String: Any], now: Date = Date()) {
        guard let runID = Self.identifier(params["runId"]),
              let attemptID = Self.identifier(params["attemptId"]),
              let providerVMID = Self.identifier(params["providerVmId"]),
              let providerTerminalID = Self.identifier(params["providerTerminalId"]),
              let session = Self.identifier(params["session"]),
              let route = params["route"] as? String, route.count <= 4096,
              let url = URL(string: route), ["ws", "wss"].contains(url.scheme?.lowercased()), url.host != nil,
              params["trustedCarrier"] as? Bool == true,
              let expiresAtUnix = (params["expiresAtUnix"] as? NSNumber)?.doubleValue, expiresAtUnix.isFinite,
              expiresAtUnix > now.timeIntervalSince1970 else { return nil }
        self.runID = runID
        self.attemptID = attemptID
        provider = (params["provider"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(128)) }
        self.providerVMID = providerVMID
        providerWorkspaceID = Self.identifier(params["providerWorkspaceId"])
        self.providerTerminalID = providerTerminalID
        self.route = route
        self.session = session
        self.expiresAtUnix = expiresAtUnix
    }

    /// A non-empty string of at most 256 characters.
    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 256 else { return nil }
        return value
    }

    /// The reply to a `run.attach` whose params ``init(params:now:)`` refused.
    static var invalidReply: [String: Any] {
        AgentPaneReply.failure(code: "run_attach_invalid", message: "The run attach endpoint is invalid or has expired.")
    }

    /// Opens the terminal through ``AgentPaneModel/onRunAttach``. Opening a tab is the person's
    /// action, so it needs their fresh gesture in the pane, used once, like `tab.open` running a
    /// line (cx-hnpxh): page script cannot attach a terminal on its own.
    @MainActor func attach(in model: AgentPaneModel) async -> [String: Any] {
        guard let onRunAttach = model.onRunAttach else { return AgentPaneModel.unsupported("run.attach") }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        do {
            try await onRunAttach(self)
            return AgentPaneReply.success()
        } catch {
            return AgentPaneReply.failure(code: "run_attach_failed", message: String(describing: error))
        }
    }
}
