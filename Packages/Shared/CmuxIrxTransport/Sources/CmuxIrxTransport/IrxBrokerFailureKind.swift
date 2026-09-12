/// A privacy-safe classification of one irx broker failure.
public enum IrxBrokerFailureKind: String, Codable, Equatable, Sendable {
    /// The account must be authenticated again.
    case authenticationRequired = "authentication_required"
    /// The operation can be retried safely.
    case transient
    /// The broker rejected the request for a non-auth reason.
    case rejected
    /// The response or local inputs were invalid.
    case invalid
}
