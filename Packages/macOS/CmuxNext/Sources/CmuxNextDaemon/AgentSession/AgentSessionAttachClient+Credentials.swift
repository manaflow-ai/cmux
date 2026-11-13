public import Foundation

extension AgentSessionAttachClient {
    /// The owner's model credential for a Cloud chat's agent as the start and its refresh send it
    /// (`credentials: {env, connection?, expires_at?}`, cmux-tui `agent_session_start.rs`): the one
    /// variable, the connection's id and the token's expiry. The machine's acpmux keeps the id and
    /// expiry (no value) so a restarted acpmux knows the chat needs this Mac again. Its descriptions
    /// name the variable, never a value.
    public struct LaunchCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let env: [String: String]
        public let connection: String?
        public let expiresAt: Date?

        public init(env: [String: String], connection: String? = nil, expiresAt: Date? = nil) {
            (self.env, self.connection, self.expiresAt) = (env, connection, expiresAt)
        }

        /// The wire object.
        var wire: [String: any Sendable] {
            var wire: [String: any Sendable] = ["env": env]
            if let connection { wire["connection"] = connection }
            if let expires = expiresAt.flatMap({ Int64(exactly: $0.timeIntervalSince1970.rounded(.down)) }) { wire["expires_at"] = expires }
            return wire
        }

        public var description: String { "LaunchCredential(\(env.keys.sorted().joined(separator: ",")), \(connection ?? "-"))" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["names": env.keys.sorted(), "connection": connection as Any], displayStyle: .struct) }
    }

    /// Whether the chat a tab shows runs on the owner's credential (`agent-session-credential-status`):
    /// its connection, the expiry of the token its agent has, whether it is a ChatGPT plan token, and
    /// whether the machine's acpmux lost it in a restart (this Mac sends it again). No value.
    public struct CredentialStatus: Sendable, Equatable {
        public let connection: String?
        public let expiresAt: Date?
        public let chatgpt: Bool
        public let lost: Bool

        public init(connection: String?, expiresAt: Date?, chatgpt: Bool, lost: Bool) {
            (self.connection, self.expiresAt, self.chatgpt, self.lost) = (connection, expiresAt, chatgpt, lost)
        }

        /// The daemon's `credential` object; nil for `null` or another shape.
        init?(_ value: Any?) {
            guard let object = value as? [String: Any] else { return nil }
            let expires = (object["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            self.init(connection: object["connection"] as? String, expiresAt: expires,
                      chatgpt: object["chatgpt"] as? Bool ?? false, lost: object["lost"] as? Bool ?? false)
        }
    }
}
