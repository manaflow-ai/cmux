import Foundation
import Testing
@testable import CmuxMobileNotifications

/// Notifications offer what the Feed offers (`ACPPermissionRequest.phoneOptions`).
/// With a single-use Allow: Allow once and Deny, never a lasting grant, which acpmux
/// refuses from a phone (`remote.lasting_grant_refused`). Without one, the options
/// stay as the agent sent them, so "Always allow" is offered and acpmux's refusal
/// says why ("Allow for this chat on the Mac") instead of the prompt showing a lone Deny.
@Suite struct PushAlwaysAllowTests {
    func permission(_ options: [(String, String)]) -> PushPayload? {
        PushPayload(userInfo: ["cmuxMobile": [
            "v": 2, "mac": "mac-1", "kind": "permission", "eventId": "p-1", "sessionId": "s-1", "permissionId": "perm-1",
            "title": "npm install", "options": options.map { ["id": $0.0, "label": $0.0, "kind": $0.1] },
        ] as [String: Any]])
    }

    @Test func withASingleUseAllowNeverOffersAlwaysAllow() throws {
        let both = try #require(permission([("yes", "allow_once"), ("always", "allow_always"), ("no", "reject_once")]))
        #expect(PushActions().plan(for: both).map(\.action) == [.allowOnce, .deny])
        #expect(PushReply(payload: both, button: .allowAlways) == nil)
        #expect(PushForm(payload: both).rows.map(\.id) == ["yes", "no"])
    }

    @Test func alwaysOnlyPromptsMatchTheFeed() throws {
        let alwaysOnly = try #require(permission([("always", "allow_always"), ("no", "reject_once")]))
        #expect(PushActions().plan(for: alwaysOnly).map(\.action) == [.allowAlways, .deny])
        #expect(try #require(PushReply(payload: alwaysOnly, button: .allowAlways)).action == .allow(optionID: "always"))
        #expect(try #require(PushReply(payload: alwaysOnly, button: .deny)).action == .deny(optionID: "no"))
        var form = PushForm(payload: alwaysOnly)
        #expect(form.rows.map(\.style) == [.allow, .deny])
        #expect(form.tap(form.rows[0]) == .allow(optionID: "always"))
        // Same options as the Feed would show for this request.
        #expect(alwaysOnly.phoneOptions.map(\.id) == ["always", "no"])
    }

    @Test func withASingleUseAllowTheLastingRejectIsHiddenToo() throws {
        let p = try #require(permission([("yes", "allow_once"), ("never", "reject_always"), ("no", "reject_once")]))
        #expect(p.phoneOptions.map(\.id) == ["yes", "no"])
        #expect(PushForm(payload: p).rows.map(\.id) == ["yes", "no"])
    }
}
