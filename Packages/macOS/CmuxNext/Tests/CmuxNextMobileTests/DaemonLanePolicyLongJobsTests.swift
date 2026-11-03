@testable import CmuxNextMobile
import Foundation
import Testing

/// The owner's long jobs from a phone (issue 13742, read-only): `jobs-list` passes with no params and
/// refuses any, and every other `jobs-*` command stays denied. The `jobs-changed` event needs no rule:
/// the lane forwards the daemon's replies and events unchanged. The Rust mirror (cmux-mobile-host
/// `policy.rs`) has the same rule (`long_jobs_list_is_read_only_and_takes_no_params`).
struct DaemonLanePolicyLongJobsTests {
    private let policy = DaemonLanePolicy(deviceID: "phone")

    @Test func jobsListIsReadOnlyAndTakesNoParams() {
        #expect(policy.evaluate(Data(#"{"id":1,"cmd":"jobs-list"}"#.utf8)) == .forward)
        for line in [
            #"{"id":1,"cmd":"jobs-list","kind":"registry.compact"}"#,
            #"{"id":1,"cmd":"jobs-list","command":"id"}"#,
            #"{"id":1,"cmd":"jobs-cancel"}"#,
            #"{"id":1,"cmd":"jobs-changed"}"#,
            #"{"id":1,"cmd":"jobs-start"}"#,
        ] {
            guard case .refuse(let answer) = policy.evaluate(Data(line.utf8)) else {
                Issue.record("forwarded \(line)")
                continue
            }
            #expect(String(decoding: answer, as: UTF8.self).contains("forbidden"))
        }
    }

    /// What crosses the lane in a job names no path: the daemon writes `detail` from its own step text.
    /// The job shape the phone decodes is the app's (`LongJob`), so a path-like detail is never needed.
    @Test func everyAllowedJobsCommandIsListed() {
        let jobs = DaemonLanePolicy.allowedCommands.filter { $0.hasPrefix("jobs-") }
        #expect(jobs == ["jobs-list"])
    }
}
