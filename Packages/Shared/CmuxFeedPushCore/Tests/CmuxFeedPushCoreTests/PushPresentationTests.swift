import Foundation
import Testing
@testable import CmuxFeedPushCore

@Suite struct PushPresentationTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func present(_ content: PushContent, _ cmux: [String: Any], prefs: NotificationPreferences? = NotificationPreferences()) -> PushPresentation {
        PushPresentation(content: content, userInfo: ["cmux": cmux], preferences: prefs, now: now, expiredBody: "No longer needs you")
    }

    @Test func assignsAMissingCategory() {
        let result = present(PushContent(title: "Run tests?"), ["feed_item": "fi_1", "kind": "approve", "type": "request", "scopes": ["session"]])
        #expect(result.content.category == "FEED_APPROVE_SESSION")
        #expect(result.kind == .permission)
        #expect(result.outcome == .shown)
    }

    @Test func keepsTheOwnersCategory() {
        let result = present(PushContent(title: "t", category: "FEED_APPROVE"), ["feed_item": "fi_1", "kind": "approve", "scopes": ["session"]])
        #expect(result.content.category == "FEED_APPROVE")
    }

    @Test func aKindTurnedOffBecomesPassiveAndSilent() {
        var prefs = NotificationPreferences()
        prefs.set(.question, enabled: false)
        let result = present(PushContent(title: "Which?", level: .timeSensitive), ["feed_item": "fi_1", "kind": "question", "type": "request"], prefs: prefs)
        #expect(result.outcome == .silenced)
        #expect(result.content.level == .passive)
        #expect(!result.content.sound)
    }

    @Test func expiredItemsSaySoQuietly() {
        let result = present(PushContent(title: "Allow?", body: "rm -rf build"), ["feed_item": "fi_1", "kind": "approve", "expires_at": 999_000_000])
        #expect(result.outcome == .expired)
        #expect(result.content.body == "No longer needs you")
        #expect(result.content.level == .passive && !result.content.sound)
        let live = present(PushContent(title: "Allow?"), ["feed_item": "fi_1", "kind": "approve", "expires_at": 1_000_001_000])
        #expect(live.outcome == .shown)
    }

    @Test func timeSensitiveFollowsThePreference() {
        var off = NotificationPreferences()
        off.timeSensitive = false
        let request: [String: Any] = ["feed_item": "fi_1", "kind": "approve", "type": "request"]
        #expect(present(PushContent(title: "t", level: .timeSensitive), request, prefs: off).content.level == .active)
        #expect(present(PushContent(title: "t", level: .timeSensitive), request).content.level == .timeSensitive)
        // A notice never breaks through Focus.
        #expect(present(PushContent(title: "t", level: .timeSensitive), ["feed_item": "fi_1", "type": "notice", "kind": "notice"]).content.level == .active)
    }

    @Test func soundOffDropsTheSound() {
        var prefs = NotificationPreferences()
        prefs.sound = false
        #expect(!present(PushContent(title: "t"), ["feed_item": "fi_1", "kind": "question"], prefs: prefs).content.sound)
    }

    @Test func withoutPreferencesNothingIsFiltered() {
        let result = present(PushContent(title: "t", level: .timeSensitive), ["feed_item": "fi_1", "kind": "question"], prefs: nil)
        #expect(result.outcome == .shown && result.content.level == .timeSensitive)
    }

    @Test func previewsAreShortenedOnWordBoundaries() {
        let long = String(repeating: "word ", count: 80)
        let cut = PushPresentation.shortened(long, to: 178)
        #expect(cut.count <= 178)
        #expect(cut.hasSuffix("word…"))
        #expect(PushPresentation.shortened("a\n\n  b", to: 10) == "a b")
        #expect(PushPresentation.shortened("short", to: 80) == "short")
        let emoji = String(repeating: "🙂", count: 100)
        #expect(PushPresentation.shortened(emoji, to: 80).count == 80)
    }

    @Test func notificationKindsMatchTheOwnersTable() {
        #expect(NotificationKind(feedKind: "approve", type: "request", category: nil) == .permission)
        for kind in ["question", "choice", "confirm", "input", "file"] {
            #expect(NotificationKind(feedKind: kind, type: "request", category: nil) == .question)
        }
        #expect(NotificationKind(feedKind: "review", type: "request", category: nil) == .planApproval)
        #expect(NotificationKind(feedKind: "anything", type: "notice", category: nil) == .finished)
        #expect(NotificationKind(feedKind: nil, type: nil, category: "cmux.terminal") == .terminalAlert)
        #expect(NotificationKind(feedKind: "sign-in", type: "request", category: nil) == nil)
    }
}
