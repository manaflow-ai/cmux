import Foundation
import Testing
@testable import CmuxNextMobile

struct MobileHostCloudLinkTests {
    @Test func requestAndResponsePreserveCorrelationAndMachineScope() throws {
        let event = try #require(MobileHostEvent(line: #"{"type":"need_cloud_links","request":17}"#))
        guard case let .needCloudLinks(request) = event else {
            Issue.record("not a Cloud directory request")
            return
        }
        let link = MobileHostCloudLink(machineID: "vm_1", teamID: "team_backend", name: "Cloud", socket: "/private/carrier.sock", owner: true)
        let line = try #require(MobileHostLaunch.cloudLinksLine(request: request, links: [link]))
        #expect(line.last == 0x0a)
        let reply = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(reply["type"] as? String == "cloud_links")
        #expect(reply["request"] as? Int == 17)
        let row = try #require((reply["links"] as? [[String: Any]])?.first)
        #expect(row["machine_id"] as? String == "vm_1")
        #expect(row["team_id"] as? String == "team_backend")
        #expect(row["owner"] as? Bool == true)
        #expect(row["socket"] as? String == "/private/carrier.sock")
    }

    @Test func malformedRequestDoesNotBecomeAnUncorrelatedLookup() {
        #expect(MobileHostEvent(line: #"{"type":"need_cloud_links"}"#) == nil)
        #expect(MobileHostEvent(line: #"{"type":"need_cloud_links","request":-1}"#) == nil)
        #expect(MobileHostEvent(line: #"{"type":"need_cloud_links","request":"17"}"#) == nil)
    }
}
