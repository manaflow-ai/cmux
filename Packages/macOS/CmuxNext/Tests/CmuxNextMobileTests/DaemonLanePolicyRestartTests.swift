@testable import CmuxNextMobile
import Foundation
import Testing

/// Restart Shell from a phone (`restart-tab`): the dead tab's own shell again on this Mac.
/// The phone names the tab and nothing else; the Rust mirror (cmux-mobile-host `policy.rs`) has
/// the same rule (`restart_shell_takes_only_the_tab`).
struct DaemonLanePolicyRestartTests {
    private let policy = DaemonLanePolicy(deviceID: "phone")

    @Test func restartShellTakesOnlyTheTab() {
        #expect(policy.evaluate(Data(#"{"id":1,"cmd":"restart-tab","surface":12}"#.utf8)) == .forward)
        for line in [
            #"{"id":1,"cmd":"restart-tab","surface":12,"command":"id"}"#,
            #"{"id":1,"cmd":"restart-tab","surface":12,"argv":["sh"]}"#,
            #"{"id":1,"cmd":"restart-tab","surface":12,"cwd":"/"}"#,
            #"{"id":1,"cmd":"restart-tab","tab":12}"#,
        ] {
            guard case .refuse(let answer) = policy.evaluate(Data(line.utf8)) else {
                Issue.record("forwarded \(line)")
                continue
            }
            #expect(String(decoding: answer, as: UTF8.self).contains("forbidden"))
        }
    }
}
