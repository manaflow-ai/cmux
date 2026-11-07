import Foundation
@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextFeed
import Testing

/// The share consent sheet (#30550) waits on the owner, so while it shows it is an open Feed request
/// (``FeedPendingConfirm``, the Feed's pinned Needs you), withdrawn when the sheet ends. The Feed can
/// decline it or bring the Mac forward, never allow a link.
@MainActor @Suite
struct AgentShareConsentFeedTests {
    @MainActor final class Owner {
        var calls: [[String: Any]] = []
        var ops: [String] { calls.compactMap { $0["op"] as? String } }
        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            calls.append(body)
            return ["value": ["item": ["id": "fi_consent0000000000001"]]]
        }
    }

    static let ask = AgentShareConsentAsk(chat: "Fix the build", ttlSecs: nil, uses: nil)

    @Test func theSheetIsAnOpenConfirmRequestThatOnlyDeclinesOrShowsTheMac() throws {
        let body = FeedPendingConfirm.postBody(AgentShareConsentSheet.feedRequest(Self.ask), key: "share-consent:1", expiresInMs: 170_000)
        #expect(body["op"] as? String == "feed.post")
        let params = try #require(body["params"] as? [String: Any])
        #expect(params["type"] as? String == "request")
        #expect(params["kind"] as? String == "confirm")
        #expect(params["title"] as? String == Self.ask.title)
        #expect(params["dedupe_key"] as? String == "share-consent:1")
        #expect(params["expires_in_ms"] as? Int == 170_000)
        let prompt = try #require(params["prompt"] as? [String: Any])
        #expect(prompt["statement"] as? String == Self.ask.lines.joined(separator: " "))
        #expect(prompt["confirm_label"] as? String == AgentShareStrings.consentShowOnMac)
        #expect(prompt["cancel_label"] as? String == Self.ask.declineTitle)
    }

    @Test func theRequestIsWithdrawnWhenTheSheetEnds() async {
        let owner = Owner()
        let feed = FeedPendingConfirm(owner: owner.call)
        let id = await feed.open(AgentShareConsentSheet.feedRequest(Self.ask), key: "share-consent:2", expiresInMs: 170_000)
        #expect(id == "fi_consent0000000000001")
        await feed.close()
        await feed.close()
        #expect(owner.ops == ["feed.post", "feed.cancel"])
        let cancel = owner.calls.last?["params"] as? [String: Any]
        #expect(cancel?["item"] as? String == "fi_consent0000000000001")
    }

    @Test func aSheetThatEndedFirstPostsNothing() async {
        let owner = Owner()
        let feed = FeedPendingConfirm(owner: owner.call)
        await feed.close()
        #expect(await feed.open(AgentShareConsentSheet.feedRequest(Self.ask), key: "share-consent:3", expiresInMs: 170_000) == nil)
        #expect(owner.calls.isEmpty)
    }

    @Test func aFeedAnswerDeclinesOrShowsTheMacNeverAllows() {
        func item(_ state: FeedItemState, _ confirmed: Bool?) -> FeedItem {
            FeedItem(id: "fi_consent0000000000001", title: "t",
                     prompt: .confirm(.init(statement: "s", confirmLabel: nil, cancelLabel: nil, destructive: false)),
                     poster: FeedPoster(kind: .app, label: "cmux"), state: state,
                     answer: confirmed.map { FeedAnswerRecord(value: .confirm($0), by: "inst_phone", device: "iPhone", at: Date()) },
                     createdAt: Date(timeIntervalSince1970: 0))
        }
        #expect(FeedPendingConfirm.confirmed(item(.answered, false)) == false)
        #expect(FeedPendingConfirm.confirmed(item(.answered, true)) == true)
        #expect(FeedPendingConfirm.confirmed(item(.open, nil)) == nil)
        #expect(FeedPendingConfirm.confirmed(item(.cancelled, nil)) == nil)
    }
}
