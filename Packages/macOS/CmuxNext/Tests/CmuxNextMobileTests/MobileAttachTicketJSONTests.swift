@testable import CmuxNextMobile
import Foundation
import Testing

/// p10-stability-167: the attach ticket reply is written through CheckedJSON, and an object JSON cannot hold
/// is the module's own ``MobileAttachTicket/Failure/unencodable``, not the Objective-C exception
/// `JSONSerialization.data(withJSONObject:)` raises (the process ends) or a CmuxNextCompat error type.
@Suite struct MobileAttachTicketJSONTests {
    @Test func anObjectJSONCannotHoldIsUnencodable() {
        #expect(throws: MobileAttachTicket.Failure.unencodable) {
            try MobileAttachTicket.Payload.write(["attach_url": "x", "expires_at": Date()])
        }
        #expect(throws: MobileAttachTicket.Failure.unencodable) {
            try MobileAttachTicket.Payload.write(["routes": [Double.nan]])
        }
    }

    @Test func aValidObjectIsWrittenWithSortedKeys() throws {
        let data = try MobileAttachTicket.Payload.write(["routes": [String](), "attach_url": "x"])
        #expect(String(decoding: data, as: UTF8.self) == #"{"attach_url":"x","routes":[]}"#)
    }
}
