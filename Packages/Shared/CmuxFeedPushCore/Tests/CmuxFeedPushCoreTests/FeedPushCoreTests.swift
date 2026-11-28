import Foundation
import Testing
@testable import CmuxFeedPushCore

@Suite struct FeedPushCoreTests {
    @Test func categoriesMatchTheOwnersNames() {
        // backend apnsPayload: FEED_<KIND upper, non-alnum -> _> for requests, FEED_NOTICE for notices.
        #expect(FeedPushCategory(rawValue: "FEED_SIGN_IN") == .signIn)
        #expect(FeedPushCategory.allCases.count == 8)
        #expect(Set(FeedPushCategory.allCases.map(\.rawValue)).count == 8)
    }

    @Test func macOnlyKindsOfferOnlyOpenOnMac() {
        for category in [FeedPushCategory.signIn, .passkey, .handoff] {
            #expect(category.actions == [.openOnMac])
            #expect(category.actions.allSatisfy { FeedAnswer(action: $0) == nil })
        }
        #expect(FeedPushCategory.choice.actions.isEmpty)
        #expect(FeedPushCategory.notice.actions.isEmpty)
    }

    @Test func answersHaveTheOwnersShape() throws {
        #expect(FeedAnswer(action: .allow)?.json["decision"] as? String == "allow")
        #expect(FeedAnswer(action: .allowForSession)?.json["scope"] as? String == "session")
        #expect(FeedAnswer(action: .deny)?.json["decision"] as? String == "deny")
        #expect(FeedAnswer(action: .confirm)?.json["confirmed"] as? Bool == true)
        #expect(FeedAnswer(action: .cancel)?.json["confirmed"] as? Bool == false)
        #expect(FeedAnswer(action: .reply, text: "  ship it ") == .text("ship it"))
        #expect(FeedAnswer(action: .reply, text: "   ") == nil)
    }

    @Test func approvalsNeedAnUnlockedPhoneDenialsDoNot() {
        #expect(FeedPushAction.allow.style == .answer(destructive: false, requiresUnlock: true))
        #expect(FeedPushAction.deny.style == .answer(destructive: true, requiresUnlock: false))
    }

    @Test func payloadParsesFeedPushesOnly() {
        let info: [AnyHashable: Any] = ["aps": ["category": "FEED_APPROVE"],
                                        "cmux": ["feed_item": "fi_1", "kind": "approve", "type": "request"]]
        #expect(FeedPushPayload(userInfo: info) == FeedPushPayload(item: "fi_1", kind: "approve", type: "request", category: .approve))
        #expect(FeedPushPayload(userInfo: ["aps": ["alert": "x"]]) == nil)
        #expect(FeedPushPayload(userInfo: ["cmux": ["feed_item": "fi_2"], "aps": ["category": "FEED_REVIEW"]])?.category == nil)
    }

    @Test func opBodiesMatchTheContract() throws {
        let token = Data([0xAB, 0x01, 0xFF])
        let register = try JSONSerialization.jsonObject(with: CloudOp.registerPushTarget(
            token: token, topic: "dev.cmux.ios.iosn2", environment: .development,
            deviceName: "Aziz", idempotencyKey: "k1").body()) as? [String: Any]
        #expect(register?["op"] as? String == "push.target.register")
        #expect(register?["idempotency_key"] as? String == "k1")
        #expect(register?["origin"] as? String == "cli")
        let params = register?["params"] as? [String: Any]
        #expect(params?["token"] as? String == "ab01ff")
        #expect(params?["environment"] as? String == "development")
        let answer = try JSONSerialization.jsonObject(with: CloudOp.answer(
            item: "fi_1", answer: .decision(allow: true, scope: nil), idempotencyKey: "k2").body()) as? [String: Any]
        #expect(answer?["origin"] as? String == "user")
        #expect((answer?["params"] as? [String: Any])?["item"] as? String == "fi_1")
    }
}

@Suite struct FeedPushResponseTests {
    let info: [AnyHashable: Any] = ["aps": ["category": "FEED_APPROVE"], "cmux": ["feed_item": "fi_9"]]
    let question: [AnyHashable: Any] = ["aps": ["category": "FEED_QUESTION"], "cmux": ["feed_item": "fi_q"]]

    @Test func bannerAnswersSendWithAStableKey() {
        let first = FeedPushResponse(actionIdentifier: "FEED_ALLOW", userText: nil, userInfo: info)
        let again = FeedPushResponse(actionIdentifier: "FEED_ALLOW", userText: nil, userInfo: info)
        #expect(first == again)
        guard case .send(let key) = first else { Issue.record("expected send"); return }
        #expect(key.idempotencyKey == "feed-answer-fi_9-FEED_ALLOW")
        #expect(key.answer == .decision(allow: true, scope: nil))
    }

    @Test func tapsAndMacOnlyActionsOpenTheItem() {
        #expect(FeedPushResponse(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", userText: nil, userInfo: info) == .open(item: "fi_9"))
        #expect(FeedPushResponse(actionIdentifier: "FEED_OPEN_ON_MAC", userText: nil, userInfo: info) == .open(item: "fi_9"))
        #expect(FeedPushResponse(actionIdentifier: "FEED_REPLY", userText: " ", userInfo: info) == .open(item: "fi_9"))
        #expect(FeedPushResponse(actionIdentifier: "FEED_ALLOW", userText: nil, userInfo: ["aps": [:]]) == .ignore)
    }
}

@Suite struct FeedPushReviewRegressionTests {
    @Test func aDomainRefusalIsNotSuccess() {
        let refused = Data(#"{"ok":false,"error":{"code":"feed.closed","retryable":false}}"#.utf8)
        #expect(CloudOpReply(body: refused) == .rejected(code: "feed.closed", retryable: false))
        #expect(CloudOpReply(body: Data(#"{"ok":true,"replayed":true}"#.utf8)) == .committed(replayed: true))
        #expect(CloudOpReply(body: Data("<html>".utf8)) == .rejected(code: "invalid_reply", retryable: true))
    }

    @Test func anActionOutsideTheItemsCategoryOnlyOpensIt() {
        // A crafted push with a confirm category cannot be answered with Allow.
        let info: [AnyHashable: Any] = ["aps": ["category": "FEED_CONFIRM"], "cmux": ["feed_item": "fi_1"]]
        #expect(FeedPushResponse(actionIdentifier: "FEED_ALLOW", userText: nil, userInfo: info) == .open(item: "fi_1"))
        #expect(FeedPushResponse(actionIdentifier: "FEED_ALLOW", userText: nil, userInfo: ["cmux": ["feed_item": "fi_1"]]) == .open(item: "fi_1"))
    }

    @Test func malformedItemIdsAreNotFeedPushes() {
        for bad in ["", "fi_", "FI_x", "fi_a/b", "fi_" + String(repeating: "a", count: 90)] {
            #expect(FeedPushPayload(userInfo: ["cmux": ["feed_item": bad]]) == nil, "\(bad)")
        }
    }

    @Test func differentRepliesGetDifferentKeys() {
        let info: [AnyHashable: Any] = ["aps": ["category": "FEED_QUESTION"], "cmux": ["feed_item": "fi_q"]]
        guard case .send(let a) = FeedPushResponse(actionIdentifier: "FEED_REPLY", userText: "yes", userInfo: info),
              case .send(let b) = FeedPushResponse(actionIdentifier: "FEED_REPLY", userText: "no", userInfo: info) else {
            Issue.record("expected sends"); return
        }
        #expect(a.idempotencyKey != b.idempotencyKey)
    }

    @Test func approvalBannerDoesNotOfferTheSessionScope() {
        #expect(FeedPushCategory.approve.actions == [.allow, .deny])
    }

    @Test func deviceNamesAreCutTo80UTF16Units() {
        let long = String(repeating: "📱", count: 60) // 120 UTF-16 units
        #expect(CloudOp.limited(long, utf16: 80).utf16.count == 80)
    }
}
