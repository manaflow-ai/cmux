public import Foundation

/// A device hub failure. Server errors carry the protocol's code
/// (`{error:{code, message}}`) and the HTTP status.
public enum DeviceHubError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The protocol's error codes; `other` keeps a code this build does not know.
    public enum Code: Sendable, Equatable {
        case badRequest, unauthorized, notFound, badSignature, staleTimestamp, replay, deviceRemoved, deviceKeyMismatch
        case notShared, permissionNone, scopeExceedsPermission, hostOffline, notHost, sessionNotPending, sessionNotActive
        case ticketInvalid, roleTaken, rateLimited, internalError
        case other(String)

        static let table: [(Code, String)] = [
            (.badRequest, "bad_request"), (.unauthorized, "unauthorized"), (.notFound, "not_found"),
            (.badSignature, "bad_signature"), (.staleTimestamp, "stale_timestamp"), (.replay, "replay"),
            (.deviceRemoved, "device_removed"), (.deviceKeyMismatch, "device_key_mismatch"), (.notShared, "not_shared"),
            (.permissionNone, "permission_none"), (.scopeExceedsPermission, "scope_exceeds_permission"),
            (.hostOffline, "host_offline"), (.notHost, "not_host"), (.sessionNotPending, "session_not_pending"),
            (.sessionNotActive, "session_not_active"), (.ticketInvalid, "ticket_invalid"), (.roleTaken, "role_taken"),
            (.rateLimited, "rate_limited"), (.internalError, "internal"),
        ]

        public init(_ raw: String) {
            self = Self.table.first { $0.1 == raw }?.0 ?? .other(raw)
        }

        public var rawValue: String {
            if case let .other(raw) = self { return raw }
            return Self.table.first { $0.0 == self }?.1 ?? ""
        }
    }

    /// No usable hub address (a DEV build's `deviceHub.url` override is not valid): the feature is off.
    case notConfigured
    /// No account token (signed out), or the server refused it.
    case notSignedIn
    case server(status: Int, code: Code, message: String)
    /// An HTTP error without the protocol's error body.
    case http(status: Int)
    case transport(String)
    case decoding(String)
    case identity(String)

    public var code: Code? {
        if case let .server(_, code, _) = self { return code }
        return nil
    }

    public var description: String {
        switch self {
        case .notConfigured: "the device hub is not configured"
        case .notSignedIn: "not signed in"
        case let .server(status, code, message): "device hub \(status) \(code.rawValue): \(message)"
        case let .http(status): "device hub HTTP \(status)"
        case let .transport(detail): "device hub transport: \(detail)"
        case let .decoding(detail): "device hub answer: \(detail)"
        case let .identity(detail): "device identity: \(detail)"
        }
    }

    struct Body: Decodable {
        struct Detail: Decodable {
            var code: String
            var message: String?
        }

        var error: Detail
    }

    /// The error for a non-2xx answer.
    static func from(status: Int, data: Data) -> DeviceHubError {
        if let body = try? JSONDecoder().decode(Body.self, from: data) {
            return .server(status: status, code: Code(body.error.code), message: body.error.message ?? "")
        }
        return status == 401 ? .notSignedIn : .http(status: status)
    }
}
