import CMUXMobileCore
import Foundation

struct MobileAttachTicketRedeemResponse: Decodable {
    let ticket: CmxAttachTicket
}

extension MobileAttachTicketRedeemResponse {
    /// Decode a redeem reply, reading `expiresAt` as an ISO-8601 timestamp.
    init(decoding data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self = try decoder.decode(Self.self, from: data)
    }
}
