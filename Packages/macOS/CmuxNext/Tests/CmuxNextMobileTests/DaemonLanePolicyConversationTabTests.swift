@testable import CmuxNextMobile
import Foundation
import Testing

/// Agent chat tabs from a phone (`new-conversation-tab`): this lane has no agent tab host of
/// this Mac to set, so it refuses them outright, even with the reviewed `agent_session` and
/// `split` fields (scripts/cmux-next/gen-phone-lane-fields.py). cmux-mobile-host is the lane that
/// forwards them (cmux-next-ios/rust/crates/cmux-mobile-host/src/policy.rs).
struct DaemonLanePolicyConversationTabTests {
    private let policy = DaemonLanePolicy(deviceID: "phone")

    private func errorCode(_ line: String) -> String? {
        guard case .refuse(let answer) = policy.evaluate(Data(line.utf8)) else {
            Issue.record("forwarded \(line)")
            return nil
        }
        let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any]
        #expect(object?["ok"] as? Bool == false)
        return object?["error_code"] as? String
    }

    @Test func agentSessionTabsAreRefusedOnThisLane() {
        for line in [
            #"{"id":1,"cmd":"new-conversation-tab","pane":4,"agent_session":{"host":"install:mac-1","harness":"claude"}}"#,
            #"{"id":1,"cmd":"new-conversation-tab","pane":4,"agent_session":{"host":"install:mac-1"},"split":{"direction":"right"}}"#,
        ] {
            #expect(errorCode(line) == "unavailable", "\(line)")
        }
    }

    @Test func programFieldsStayForbidden() {
        let line = #"{"id":1,"cmd":"new-conversation-tab","pane":4,"agent_session":{"host":"install:mac-1"},"command":"sh"}"#
        #expect(errorCode(line) == "forbidden")
    }
}
