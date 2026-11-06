@testable import CmuxNextApp
import CmuxNextFeedClient
import CmuxNextMobile
import Foundation
import Testing

/// The Feed's pinned open requests reach the iPhone host (manaflow-ai/cmux#33818): a PR held
/// for trial goes with its title and link; an agent approval (the phone has it from acpmux), a
/// notice and a closed request do not. The items are the daemon's Needs you view
/// (`feed.view.read {layout: needs_you}`).
@MainActor @Suite
struct FeedNeedsYouPhoneTests {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let pr = URL(string: "https://github.com/acme/app/pull/30817")

    func item(_ id: String, kind: String = "review", type: String = "request", context: String = #"{"url":"https://github.com/acme/app/pull/30817"}"#,
              state: String = "open", github: String = "null") throws -> FeedDaemonItem {
        try .wire(#"""
        {"id":"\#(id)","home":"local:github","type":"\#(type)","kind":"\#(kind)","title":"GitHub","body":"acme/app#30817",
         "context":\#(context),"poster":{"kind":"integration","label":"GitHub"},"state":"\#(state)",
         "created_at":1700000000000,"github":\#(github)}
        """#)
    }

    @Test func aHeldPullRequestGoesToThePhoneWithItsTitleAndLink() throws {
        let held = try item("fi_held", github: #"{"title":"Spaces switcher","repo":"acme/app","number":30817,"url":"https://github.com/acme/app/pull/30817"}"#)
        #expect(FeedNeedsYouPhone.requests([held]) == [MobileHostNeedsYouRequest(
            id: "fi_held", title: "Spaces switcher", body: "acme/app#30817", kind: "review", source: "GitHub",
            url: Self.pr, createdAt: Self.date)])
    }

    @Test func approvalsFromAcpmuxNoticesAndClosedRequestsStayOff() throws {
        let pinned = [
            try item("fi_agent", context: #"{"acp_session":"s1"}"#),
            try item("fi_notice", kind: "notice", type: "notice"),
            try item("fi_done", state: "answered"),
            try item("fi_open"),
        ]
        #expect(FeedNeedsYouPhone.requests(pinned).map(\.id) == ["fi_open"])
    }

    /// Before the owner's first snapshot nothing goes: an empty set would close the phone's rows.
    @Test func nothingGoesUntilTheFeedLoaded() throws {
        func view(_ json: String) throws -> FeedDaemonView {
            try JSONDecoder().decode(FeedDaemonView.self, from: Data(json.utf8))
        }
        #expect(FeedNeedsYouPhone.current(try view(#"{"loaded":false,"connection":{"state":"connecting"},"groups":[]}"#)) == nil)
        #expect(FeedNeedsYouPhone.current(try view(#"{"loaded":true,"connection":{"state":"offline"},"groups":[]}"#)) == nil)
        #expect(FeedNeedsYouPhone.current(try view(#"{"loaded":true,"connection":{"state":"connected"},"groups":[]}"#)) == [])
    }
}
