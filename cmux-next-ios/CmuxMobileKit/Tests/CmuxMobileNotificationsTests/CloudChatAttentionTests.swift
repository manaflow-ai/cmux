import Foundation
import Testing
@testable import CmuxMobileNotifications

@Suite struct CloudChatAttentionTests {
    func fields(kind: String = "question") -> [String: Any] {
        ["kind": kind, "event_id": "event-1", "machine_id": "cloud-1", "session_id": "session-1", "team_id": "team-1"]
    }

    @Test func readsEachAttentionKindAndKeepsTheCloudScope() throws {
        for kind in ["question", "permission", "done"] {
            let route = try #require(CloudChatAttention(userInfo: ["cmux": ["cloud": fields(kind: kind)]]))
            #expect(route.kind.rawValue == kind)
            #expect(route.machineID == "cloud-1")
            #expect(route.sessionID == "session-1")
            #expect(route.teamID == "team-1")
        }
    }

    @Test func bareOrPartialIdentifiersCannotSelectALocalChat() {
        #expect(CloudChatAttention(userInfo: fields()) == nil)
        #expect(CloudChatAttention(userInfo: ["cmuxMobile": fields()]) == nil)
        for key in ["kind", "event_id", "machine_id", "session_id", "team_id"] {
            var cloud = fields()
            cloud[key] = nil
            #expect(CloudChatAttention(userInfo: ["cmux": ["cloud": cloud]]) == nil)
            cloud[key] = ""
            #expect(CloudChatAttention(userInfo: ["cmux": ["cloud": cloud]]) == nil)
        }
        #expect(CloudChatAttention(userInfo: ["cmux": ["cloud": fields(kind: "approve")]]) == nil)
    }

    @Test func identifiersAreNotTakenFromTheDeepLink() throws {
        var cloud = fields()
        cloud["deep_link"] = "cmux://cloud/chat/another-machine/another-session"
        let route = try #require(CloudChatAttention(userInfo: ["cmux": ["cloud": cloud]]))
        #expect(route.machineID == "cloud-1")
        #expect(route.sessionID == "session-1")
    }
}
