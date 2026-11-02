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
        let link = MobileHostCloudLink(machineID: "vm_1", teamID: "team_backend", name: "Cloud", socket: "/private/carrier.sock", owner: true,
                                       status: "running", ran: true)
        let asleep = MobileHostCloudLink(machineID: "vm_2", teamID: "team_backend", name: "Asleep", socket: nil, owner: true,
                                         status: "paused", ran: true)
        let line = try #require(MobileHostLaunch.cloudLinksLine(request: request, links: MobileHostCloudLinks(paid: true, links: [link, asleep])))
        #expect(line.last == 0x0a)
        let reply = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(reply["type"] as? String == "cloud_links")
        #expect(reply["request"] as? Int == 17)
        #expect(reply["paid"] as? Bool == true)
        let rows = try #require(reply["links"] as? [[String: Any]])
        let row = try #require(rows.first)
        #expect(row["machine_id"] as? String == "vm_1")
        #expect(row["team_id"] as? String == "team_backend")
        #expect(row["owner"] as? Bool == true)
        #expect(row["socket"] as? String == "/private/carrier.sock")
        #expect(row["status"] as? String == "running")
        #expect(row["ran"] as? Bool == true)
        // A machine without a live link says so with an explicit null socket, never a missing key.
        let sleeping = try #require(rows.last)
        #expect(sleeping.keys.contains("socket"))
        #expect(sleeping["socket"] is NSNull)
        #expect(sleeping["status"] as? String == "paused")
        #expect(sleeping["ran"] as? Bool == true)
    }

    /// Unknown limits read as not paid, so the phone's Computer card stays hidden.
    @Test func anUnknownPlanIsNotPaid() throws {
        let line = try #require(MobileHostLaunch.cloudLinksLine(request: 3, links: MobileHostCloudLinks()))
        let reply = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(reply["paid"] as? Bool == false)
        #expect((reply["links"] as? [Any])?.isEmpty == true)
    }

    @Test func malformedRequestDoesNotBecomeAnUncorrelatedLookup() {
        #expect(MobileHostEvent(line: #"{"type":"need_cloud_links"}"#) == nil)
        #expect(MobileHostEvent(line: #"{"type":"need_cloud_links","request":-1}"#) == nil)
        #expect(MobileHostEvent(line: #"{"type":"need_cloud_links","request":"17"}"#) == nil)
    }
}
