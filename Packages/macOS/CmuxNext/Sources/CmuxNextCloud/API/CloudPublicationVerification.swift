import Foundation

/// Verification is intentionally kept to its state. DNS records and provider
/// details remain server-side and are not surfaced by the read action.
public struct CloudPublicationVerification: Sendable, Hashable, Decodable {
    public var verificationId: String?
    public var domain: String?
    public var state: String?
}
