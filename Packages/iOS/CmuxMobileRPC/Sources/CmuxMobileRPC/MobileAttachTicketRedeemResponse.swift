import CMUXMobileCore
import Foundation

struct MobileAttachTicketRedeemResponse: Decodable {
    let ticket: CmxAttachTicket

    static func decode(_ data: Data) throws -> MobileAttachTicketRedeemResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileAttachTicketRedeemResponse.self, from: data)
    }
}
