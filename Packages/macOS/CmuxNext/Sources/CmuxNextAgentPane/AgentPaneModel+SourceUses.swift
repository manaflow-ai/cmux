import CmuxNextPages
import CmuxNextSettings
import Foundation

extension AgentPaneModel {
    /// A local document's reverse links use only the chat that opened it. Remote carriers
    /// need their own authenticated bridge; a socket on this Mac is never their fallback.
    public var canReadSourceUses: Bool {
        !chatIsElsewhere && hasHandshake && sessionId != nil && (transport.acpmuxSocket ?? transport.socketPath) != nil
    }

    public func sourceUses(uri: String, session: String, cursor: String?) async throws -> JSONValue {
        guard canReadSourceUses, sessionId == session, let socket = transport.acpmuxSocket ?? transport.socketPath else {
            throw PageError.closed
        }
        var params: [String: any Sendable] = ["sessionId": session, "uri": uri, "limit": 20]
        if let cursor { params["cursor"] = cursor }
        let result = try await AcpmuxStatusClient.call(socketPath: socket, method: "_acpmux/source_uses", params: params,
                                                     deadline: .seconds(10))
        guard canReadSourceUses, sessionId == session,
              (transport.acpmuxSocket ?? transport.socketPath) == socket,
              let json = JSONValue(foundation: result), json["sessionId"]?.stringValue == session,
              json["uri"]?.stringValue == uri else { throw PageError.closed }
        return json
    }
}
