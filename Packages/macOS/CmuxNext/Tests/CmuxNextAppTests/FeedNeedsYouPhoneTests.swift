@testable import CmuxNextApp
import CmuxNextFeed
import CmuxNextMobile
import Foundation
import Testing

/// The Feed's pinned open requests reach the iPhone host (manaflow-ai/cmux#33818): a PR held
/// for trial goes with its title and link; an agent approval (the phone has it from acpmux), a
/// notice and a closed request do not.
@MainActor @Suite
struct FeedNeedsYouPhoneTests {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let pr = URL(string: "https://github.com/acme/app/pull/30817")

    func item(_ id: String, prompt: FeedPrompt = .review(.init(subject: .pr, ref: "https://github.com/acme/app/pull/30817")),
              context: FeedContext = FeedContext(url: pr), state: FeedItemState = .open) -> FeedItem {
        FeedItem(id: id, home: .local(install: "github"), title: "GitHub", body: "acme/app#30817", prompt: prompt,
                 context: context, poster: FeedPoster(kind: .integration, label: "GitHub"), state: state, createdAt: Self.date)
    }

    @Test func aHeldPullRequestGoesToThePhoneWithItsTitleAndLink() {
        let detail = GitHubFeedDetail(repository: "acme/app", number: 30817, url: Self.pr, title: "Spaces switcher", updatedAt: Self.date)
        let requests = FeedNeedsYouPhone.requests([item("fi_held")]) { $0.id == "fi_held" ? detail : nil }
        #expect(requests == [MobileHostNeedsYouRequest(
            id: "fi_held", title: "Spaces switcher", body: "acme/app#30817", kind: "review", source: "GitHub",
            url: Self.pr, createdAt: Self.date)])
    }

    @Test func approvalsFromAcpmuxNoticesAndClosedRequestsStayOff() {
        let pinned = [
            item("fi_agent", context: FeedContext(acpSession: "s1")),
            item("fi_notice", prompt: .notice),
            item("fi_done", state: .answered),
            item("fi_open"),
        ]
        #expect(FeedNeedsYouPhone.requests(pinned) { _ in nil }.map(\.id) == ["fi_open"])
    }

    /// Before the owner's first snapshot nothing goes: an empty set would close the phone's rows.
    @Test func nothingGoesUntilTheFeedLoaded() {
        let model = FeedModel(source: InMemoryFeedSource(snapshot: FeedSnapshot(revision: 0, user: "u", device: "Mac", items: [])))
        #expect(FeedNeedsYouPhone.current(model) { _ in nil } == nil)
        model.start()
        #expect(FeedNeedsYouPhone.current(model) { _ in nil } == [])
    }
}
