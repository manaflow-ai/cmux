import Foundation
import Testing
@testable import CmuxFeedPushCore

@Suite struct FeedPushActionMappingTests {
    func info(_ category: String, item: String = "fi_1") -> [AnyHashable: Any] {
        ["aps": ["category": category], "cmux": ["feed_item": item]]
    }

    @Test func scopedApprovalOffersOnceAndSession() throws {
        #expect(FeedPushCategory.approveScoped.actions == [.allowOnce, .allowForSession, .deny])
        guard case .perform(let once) = FeedPushResponse(actionIdentifier: "FEED_ALLOW_ONCE", userText: nil, userInfo: info("FEED_APPROVE_SESSION")),
              case .perform(let session) = FeedPushResponse(actionIdentifier: "FEED_ALLOW_SESSION", userText: nil, userInfo: info("FEED_APPROVE_SESSION")) else {
            Issue.record("expected performs"); return
        }
        #expect(once.change == .answer(.decision(allow: true, scope: "once")))
        #expect(session.change == .answer(.decision(allow: true, scope: "session")))
        // The plain approve banner cannot answer with a scope.
        #expect(FeedPushResponse(actionIdentifier: "FEED_ALLOW_SESSION", userText: nil, userInfo: info("FEED_APPROVE")) == .open(item: "fi_1"))
    }

    @Test func denyNeverCarriesAScope() {
        #expect(FeedAnswer.decision(allow: false, scope: "session").json["scope"] == nil)
    }

    @Test func planApproveAndRequestChanges() {
        guard case .perform(let approve) = FeedPushResponse(actionIdentifier: "FEED_PLAN_APPROVE", userText: nil, userInfo: info("FEED_PLAN")),
              case .perform(let changes) = FeedPushResponse(actionIdentifier: "FEED_PLAN_CHANGES", userText: " add tests ", userInfo: info("FEED_PLAN")) else {
            Issue.record("expected performs"); return
        }
        #expect(approve.change == .answer(.verdict(approve: true, comment: nil)))
        #expect(changes.change == .answer(.verdict(approve: false, comment: "add tests")))
        #expect(changes.idempotencyKey.hasPrefix("feed-push-fi_1-FEED_PLAN_CHANGES-"))
        #expect(FeedAnswer.verdict(approve: false, comment: "x").json["verdict"] as? String == "request_changes")
        // An empty comment opens the item so the user can write one.
        #expect(FeedPushResponse(actionIdentifier: "FEED_PLAN_CHANGES", userText: "  ", userInfo: info("FEED_PLAN")) == .open(item: "fi_1"))
    }

    @Test func markReadIsAReadIntent() {
        let response = FeedPushResponse(actionIdentifier: "FEED_MARK_READ", userText: nil, userInfo: info("FEED_NOTICE"))
        #expect(response == .perform(FeedPushIntent(item: "fi_1", change: .read, idempotencyKey: "feed-push-fi_1-FEED_MARK_READ")))
        #expect(FeedPushResponse(actionIdentifier: "FEED_MARK_READ", userText: nil, userInfo: info("FEED_APPROVE")) == .open(item: "fi_1"))
    }

    @Test func theDeliveredCategoryWinsOverTheApsOne() {
        // The extension assigned FEED_APPROVE_SESSION to a push whose aps named none.
        let raw: [AnyHashable: Any] = ["cmux": ["feed_item": "fi_2", "kind": "approve", "scopes": ["once", "session"]]]
        let response = FeedPushResponse(actionIdentifier: "FEED_ALLOW_SESSION", userText: nil,
                                        categoryIdentifier: "FEED_APPROVE_SESSION", userInfo: raw)
        guard case .perform(let intent) = response else { Issue.record("expected perform"); return }
        #expect(intent.change == .answer(.decision(allow: true, scope: "session")))
    }

    @Test func categoriesDeriveLikeTheOwner() {
        #expect(FeedPushCategory(feedKind: "approve", type: "request", scopes: ["once"], subject: nil) == .approve)
        #expect(FeedPushCategory(feedKind: "approve", type: "request", scopes: ["once", "session"], subject: nil) == .approveScoped)
        #expect(FeedPushCategory(feedKind: "review", type: "request", scopes: [], subject: "plan") == .plan)
        #expect(FeedPushCategory(feedKind: "review", type: "request", scopes: [], subject: "diff") == .review)
        #expect(FeedPushCategory(feedKind: "sign-in", type: "request", scopes: [], subject: nil) == .signIn)
        #expect(FeedPushCategory(feedKind: "anything", type: "notice", scopes: [], subject: nil) == .notice)
        #expect(FeedPushCategory(feedKind: "x-acme.thing", type: "request", scopes: [], subject: nil) == nil)
    }

    @Test func payloadDecodesTheNewFields() {
        let raw: [AnyHashable: Any] = ["cmux": ["feed_item": "fi_3", "kind": "approve", "scopes": ["once", 4, "session"],
                                                "subject": "plan", "expires_at": 1_800_000_000_000]]
        let payload = FeedPushPayload(userInfo: raw)
        #expect(payload?.scopes == ["once", "session"])
        #expect(payload?.subject == "plan")
        #expect(payload?.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(payload?.resolvedCategory == .approveScoped)
    }
}
