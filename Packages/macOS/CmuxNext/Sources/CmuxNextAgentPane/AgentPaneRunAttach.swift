import Foundation

/// A one-use Run terminal target redeemed by the cloud control plane. Provider credentials stay
/// inside this value and never enter the page's shell command construction.
public nonisolated struct AgentPaneRunAttach: Equatable, Sendable {
    public let runID: String
    public let attemptID: String
    public let route: String
    public let token: String
    public let session: String
    public let expiresAtUnix: Double

    public init?(params: [String: Any]?) {
        guard let runID = Self.identifier(params?["runId"]),
              let attemptID = Self.identifier(params?["attemptId"]),
              let route = params?["route"] as? String,
              let url = URL(string: route), url.scheme.map({ ["wss", "ws"].contains($0.lowercased()) }) == true,
              route.utf8.count <= 8192,
              let token = params?["token"] as? String, !token.isEmpty, token.utf8.count <= 2048,
              let session = Self.identifier(params?["session"]),
              let expiresAtUnix = (params?["expiresAtUnix"] as? NSNumber)?.doubleValue, expiresAtUnix > 0 else { return nil }
        self.runID = runID
        self.attemptID = attemptID
        self.route = route
        self.token = token
        self.session = session
        self.expiresAtUnix = expiresAtUnix
    }

    /// Compatibility bridge for the current terminal tab implementation. The operation is native,
    /// so the page never gets to choose an arbitrary command; the direct cmux transport can replace
    /// this command path without changing the board contract.
    public var shellCommand: String { "cmux remote connect \(Self.quote(route)) --carrier" }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }) else { return nil }
        return value
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
