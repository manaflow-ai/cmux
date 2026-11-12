@testable import CmuxNextMobile
import Foundation
import Testing

/// This Mac's appearance over the Mac app's phone splice (`appearance-v1`,
/// cmux-next-ios/PROTOCOL.md "Appearance"): the Rust mirror (cmux-mobile-host `policy.rs`) has the
/// same rules (`phone_reads_the_appearance_without_the_background_path`).
struct DaemonLanePolicyAppearanceTests {
    private let policy = DaemonLanePolicy(deviceID: "phone-1")

    @Test func phoneReadsTheAppearance() {
        #expect(policy.evaluate(Data(#"{"id":"a1","cmd":"get-appearance"}"#.utf8)) == .forward)
    }

    @Test func theBackgroundPathIsStripped() throws {
        let verdict = policy.evaluate(Data(#"{"id":"a2","cmd":"get-appearance","include_path":true}"#.utf8))
        guard case .rewrite(let data) = verdict else {
            Issue.record("not rewritten: \(verdict)")
            return
        }
        let sent = try #require((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        #expect(sent["include_path"] == nil)
        #expect(sent["cmd"] as? String == "get-appearance")
        #expect(sent["id"] as? String == "a2")
    }

    @Test func phoneNeverSetsTheBackground() {
        let line = #"{"id":"a3","cmd":"set-appearance-background","background":null}"#
        guard case .refuse = policy.evaluate(Data(line.utf8)) else {
            Issue.record("forwarded \(line)")
            return
        }
    }
}
