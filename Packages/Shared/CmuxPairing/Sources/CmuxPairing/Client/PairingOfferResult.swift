public import Foundation

/// What the owner answers to `pairing.offer`: the QR link and its expiry.
public struct PairingOfferResult: Hashable, Sendable, Codable {
    public var offer: String
    public var offerID: String
    /// Milliseconds since 1970.
    public var expiresAt: Int64
    public var link: String

    enum CodingKeys: String, CodingKey {
        case offer, link
        case offerID = "offer_id"
        case expiresAt = "expires_at"
    }

    public var url: URL? { URL(string: link) }
}
