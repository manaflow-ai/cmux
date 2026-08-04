import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite
struct MobileEventProbeResponseTests {
    @Test
    func hostPayloadRoundTripsThroughClientDecoder() throws {
        let response = MobileEventProbeResponse(
            streamID: "events",
            subscribed: true,
            eventTransport: "iroh_server_events_v1"
        )
        let data = try JSONSerialization.data(withJSONObject: response.jsonObject)

        #expect(try MobileEventProbeResponse.decode(data) == response)
    }
}
