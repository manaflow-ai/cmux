public import CmuxMobileWire
import Foundation

/// Decodes `read signal.turn_credentials` results
/// (`{ice_servers [{urls, username?, credential?}], expires_at}`, expiry in
/// epoch milliseconds).
public struct TurnCredentialsDecoder: Sendable {
    public init() {}

    public func decode(_ value: JSONValue) -> ICEConfiguration? {
        guard case let .object(fields) = value, case let .array(entries)? = fields["ice_servers"] else { return nil }
        var servers: [ICEServer] = []
        for entry in entries {
            guard case let .object(server) = entry, case let .array(rawURLs)? = server["urls"] else { return nil }
            let urls = rawURLs.compactMap { url -> String? in
                guard case let .string(text) = url,
                      text.hasPrefix("stun:") || text.hasPrefix("turn:") || text.hasPrefix("turns:") else { return nil }
                return text
            }
            guard !urls.isEmpty else { continue }
            var username: String?
            if case let .string(name)? = server["username"] { username = name }
            var credential: String?
            if case let .string(secret)? = server["credential"] { credential = secret }
            servers.append(ICEServer(urls: urls, username: username, credential: credential))
        }
        var expiresAt: Date?
        switch fields["expires_at"] {
        case let .int(ms)?: expiresAt = Date(timeIntervalSince1970: Double(ms) / 1000)
        case let .double(ms)?: expiresAt = Date(timeIntervalSince1970: ms / 1000)
        default: break
        }
        return ICEConfiguration(servers: servers, expiresAt: expiresAt)
    }
}
