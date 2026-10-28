@testable import CmuxNextMobile
import Foundation
import Testing

/// The terminal sizing policy over the Mac app's phone splice (`host-size-policy-v1`,
/// cmux-next-ios/PROTOCOL.md): the Rust mirror (cmux-mobile-host `policy.rs`) has the same
/// rules (`phone_sizing_commands_pass_and_client_info_is_marked_remote`,
/// `phone_sub_view_identity_names_no_user_or_device`).
struct DaemonLanePolicySizingTests {
    private let policy = DaemonLanePolicy(deviceID: "phone-1")

    private func rewritten(_ line: String) -> [String: Any]? {
        guard case .rewrite(let data) = policy.evaluate(Data(line.utf8)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @Test func clientInfoIsMarkedRemoteWithTheLinksDevice() throws {
        let sent = try #require(rewritten(
            #"{"id":"c1","cmd":"set-client-info","device_kind":"mac","device_id":"someone-else","remote":false}"#))
        #expect(sent["remote"] as? Bool == true)
        #expect(sent["device_id"] as? String == "phone-1")
        // A phone that names itself a Mac is still remote: never one of this Mac's views.
        #expect(sent["device_kind"] as? String == "mac")
        #expect(sent["id"] as? String == "c1")
    }

    @Test func sizingCommandsPassAndPolicyOverridesDoNot() {
        for line in [
            #"{"id":"s1","cmd":"get-size-state","surface":7}"#,
            #"{"id":"s2","cmd":"note-size-activity","surface":7}"#,
            #"{"id":"s3","cmd":"get-host-size-policy","surface":7}"#,
            #"{"id":"s4","cmd":"set-host-size-policy","policy":{"mode":"priority","order":["mac"]}}"#,
        ] {
            #expect(policy.evaluate(Data(line.utf8)) == .forward, "\(line)")
        }
        for line in [
            #"{"id":"s5","cmd":"set-size-policy","surface":7,"policy":{"mode":"fixed"}}"#,
            #"{"id":"s6","cmd":"set-size-counts","surface":7,"counts":false}"#,
        ] {
            guard case .refuse = policy.evaluate(Data(line.utf8)) else {
                Issue.record("forwarded \(line)")
                continue
            }
        }
    }

    @Test func subViewIdentityNamesNoUserOrDevice() throws {
        let sent = try #require(rewritten(
            #"{"id":"r1","cmd":"resize-attached-view","surface":7,"view":"v","cols":40,"rows":20,"identity":{"user_id":"u","device_id":"ipad-1","device_kind":"ipad","device_name":"iPad"}}"#))
        let identity = try #require(sent["identity"] as? [String: Any])
        #expect(identity["user_id"] == nil)
        #expect(identity["device_id"] == nil)
        #expect(identity["device_kind"] as? String == "ipad")
        #expect(sent["cols"] as? Int == 40)
        #expect(policy.evaluate(Data(#"{"id":"r2","cmd":"resize-attached-view","surface":7,"view":"v","cols":40,"rows":20}"#.utf8)) == .forward)
    }
}
