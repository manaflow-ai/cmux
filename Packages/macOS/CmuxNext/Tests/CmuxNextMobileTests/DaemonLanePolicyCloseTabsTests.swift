@testable import CmuxNextMobile
import Foundation
import Testing

/// Close Tab from a phone in one round trip (`close-tabs`), stamped with the phone's trace id. `_meta`
/// carries that id and nothing else; the Rust mirror (cmux-mobile-host `policy.rs`) has the same rule
/// (`close_tabs_takes_a_trace_id_only`).
struct DaemonLanePolicyCloseTabsTests {
    private let policy = DaemonLanePolicy(deviceID: "phone")

    @Test func closeTabsTakesATraceIDOnly() {
        for line in [
            #"{"_meta":{"traceId":"4bf92f3577b34da6a3ce929d0e0e4736"},"cmd":"close-tabs","end_terminals":true,"id":"m1","surfaces":[7]}"#,
            #"{"cmd":"close-tabs","id":"m1","surfaces":[7]}"#,
            #"{"_meta":{"traceId":"ab"},"cmd":"restart-tab","id":"m2","surface":7}"#,
        ] {
            #expect(policy.evaluate(Data(line.utf8)) == .forward, "\(line)")
        }
        for line in [
            #"{"_meta":{"traceId":"ab","acpmux":{}},"cmd":"close-tabs","id":"m1","surfaces":[7]}"#,
            #"{"_meta":{"traceId":"a b"},"cmd":"close-tabs","id":"m1","surfaces":[7]}"#,
            #"{"_meta":{"traceId":""},"cmd":"close-tabs","id":"m1","surfaces":[7]}"#,
            #"{"_meta":{"traceId":7},"cmd":"close-tabs","id":"m1","surfaces":[7]}"#,
            #"{"_meta":"x","cmd":"close-tabs","id":"m1","surfaces":[7]}"#,
            #"{"cmd":"close-tabs","id":"m1","surfaces":[7],"command":"id"}"#,
            "{\"_meta\":{\"traceId\":\"\(String(repeating: "a", count: 129))\"},\"cmd\":\"close-tabs\",\"id\":\"m1\",\"surfaces\":[7]}",
        ] {
            guard case .refuse(let answer) = policy.evaluate(Data(line.utf8)) else {
                Issue.record("forwarded \(line)")
                continue
            }
            #expect(String(decoding: answer, as: UTF8.self).contains("forbidden"))
        }
    }
}
