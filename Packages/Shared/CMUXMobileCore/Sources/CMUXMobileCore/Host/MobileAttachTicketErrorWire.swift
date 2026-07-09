import Foundation

/// The wire fields for a failed `mobile.attach.ticket.create` reply: the error
/// `code`, the human-readable `message`, and the optional `data` map.
///
/// ``MobileAttachTicketRequestCoordinator`` produces this value; the app wraps
/// it into its `V2CallResult.err(code:message:data:)`. The `data` values are all
/// strings (the echoed `route_id`/`route_kind` or a `String(describing:)` of the
/// underlying error), so the map is `[String: String]`; the app widens it to the
/// `[String: Any]` the wire result expects.
public struct MobileAttachTicketErrorWire: Sendable, Equatable {
    /// The wire error code (`unavailable` or `internal_error`).
    public let code: String

    /// The human-readable error message.
    public let message: String

    /// The optional error `data` map, or `nil` when there is no extra context.
    public let data: [String: String]?

    /// Creates the wire-error fields.
    /// - Parameters:
    ///   - code: The wire error code.
    ///   - message: The human-readable error message.
    ///   - data: The optional error `data` map.
    public init(code: String, message: String, data: [String: String]?) {
        self.code = code
        self.message = message
        self.data = data
    }
}
