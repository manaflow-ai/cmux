import Foundation
import Testing
@testable import CmuxMobileNotifications

/// verify/push-matrix.md, failure 3: acpmux refuses a lasting grant from a
/// phone (`remote.lasting_grant_refused`), so a notification never offers
/// "Always allow": the person would pass Face ID only to read "Not sent".
@Suite struct PushAlwaysAllowTests {
    func permission(_ options: [(String, String)]) -> PushPayload? {
        PushPayload(userInfo: ["cmuxMobile": [
            "v": 2, "mac": "mac-1", "kind": "permission", "eventId": "p-1", "sessionId": "s-1", "permissionId": "perm-1",
            "title": "npm install", "options": options.map { ["id": $0.0, "label": $0.0, "kind": $0.1] },
        ] as [String: Any]])
    }

    @Test func neverOffersAlwaysAllow() throws {
        let both = try #require(permission([("yes", "allow_once"), ("always", "allow_always"), ("no", "reject_once")]))
        #expect(PushActions().plan(for: both).map(\.action) == [.allowOnce, .deny])
        let alwaysOnly = try #require(permission([("always", "allow_always"), ("no", "reject_once")]))
        #expect(PushActions().plan(for: alwaysOnly).map(\.action) == [.deny])
        #expect(PushReply(payload: alwaysOnly, button: .allowAlways) == nil)
    }
}
