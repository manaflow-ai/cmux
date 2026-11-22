public import Foundation

/// `chief-inspect` (cmux-tui `server/chief_inspect.rs`, `chief-inspect-v1`):
/// the Chief memory inspector's read-only API, which the brain's daemon
/// forwards to the brain host's tools socket. The daemon answers only the
/// owner's trusted connection (a local client, or the link's owner_session
/// splice); everything else is refused with `origin.forbidden`.
public struct ChiefInspectRequest: DaemonRequest {
    public typealias Response = ChiefInspectResult
    public static let command = "chief-inspect"
    /// One of the seven `/api/...` paths.
    public var path: String
    public var query: [String: String]

    public init(path: String, query: [String: String]) {
        self.path = path
        self.query = query
    }
}

/// The brain's answer: an HTTP-like status, its JSON body or its reason.
public struct ChiefInspectResult: Decodable, Sendable, Equatable {
    public var status: UInt64
    public var body: JSONValue?
    public var error: String?

    public init(status: UInt64, body: JSONValue?, error: String?) {
        self.status = status
        self.body = body
        self.error = error
    }
}
