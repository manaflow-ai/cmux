@testable import CmuxNextMobile
import Foundation
import Testing

/// Reopen / Delete Saved Tab Group from a phone: the saved id and a pane only. The Rust
/// mirror (cmux-mobile-host `policy.rs`) has the same rule
/// (`saved_tab_groups_take_only_the_saved_id_and_a_pane`).
struct DaemonLanePolicySavedGroupTests {
    private let policy = DaemonLanePolicy(deviceID: "phone")

    @Test func savedTabGroupsTakeOnlyTheSavedIDAndAPane() {
        for line in [
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"saved_0123abcd","pane":4}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"saved_0123abcd","pane":"pane_01J","transaction":"tx-1"}"#,
            #"{"id":1,"cmd":"delete-saved-tab-group","saved":"saved_0123abcd"}"#,
            #"{"id":1,"cmd":"list-saved-tab-groups"}"#,
        ] {
            #expect(policy.evaluate(Data(line.utf8)) == .forward, "\(line)")
        }
        for line in [
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"command":"id"}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"argv":["sh"]}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"cwd":"/"}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"env":{"BASH_ENV":"/tmp/x"}}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"terminal_host":"h"}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"members":[]}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"origin":"user"}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s"}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":-1}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":true}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":"a b"}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"s","pane":4,"transaction":""}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":"../x","pane":4}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","saved":12,"pane":4}"#,
            #"{"id":1,"cmd":"reopen-saved-tab-group","pane":4}"#,
            #"{"id":1,"cmd":"delete-saved-tab-group","saved":"s","cwd":"/"}"#,
            #"{"id":1,"cmd":"delete-saved-tab-group"}"#,
        ] {
            guard case .refuse(let answer) = policy.evaluate(Data(line.utf8)) else {
                Issue.record("forwarded \(line)")
                continue
            }
            #expect(String(decoding: answer, as: UTF8.self).contains("forbidden"))
        }
    }
}
