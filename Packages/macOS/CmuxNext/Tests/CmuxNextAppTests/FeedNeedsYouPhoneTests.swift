@testable import CmuxNextApp
import CmuxNextFeedClient
@testable import CmuxNextMobile
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
        #expect(FeedNeedsYouPhone.current(try view(#"{"account":{"id":"stack:p:a","user":"a"},"loaded":false,"connection":{"state":"connecting"},"groups":[]}"#)) == nil)
        #expect(FeedNeedsYouPhone.current(try view(#"{"account":{"id":"stack:p:a","user":"a"},"loaded":true,"connection":{"state":"offline"},"groups":[]}"#)) == nil)
        #expect(FeedNeedsYouPhone.current(try view(#"{"account":{"id":"stack:p:a","user":"a"},"loaded":true,"connection":{"state":"connected"},"groups":[]}"#)) == [])
        // Offline once loaded: the mirror kept the cloud requests and the local ones stay live, so changes still go.
        #expect(FeedNeedsYouPhone.current(try view(#"{"account":{"id":"stack:p:a","user":"a"},"loaded":true,"connection":{"state":"disconnected","reason":"offline"},"groups":[]}"#)) == [])
        #expect(FeedNeedsYouPhone.current(try view(#"{"account":{"id":"stack:p:a","user":"a"},"loaded":false,"connection":{"state":"disconnected","reason":"offline"},"groups":[]}"#)) == nil)
        // Signed out there is no account to send for (the projection forgets instead).
        #expect(FeedNeedsYouPhone.current(try view(#"{"loaded":false,"connection":{"state":"disconnected","reason":"signed_out"},"groups":[]}"#)) == nil)
    }

    /// A first cloud connection that fails (manaflow-ai/cmux#37378 review): the daemon's view is
    /// empty, disconnected and not loaded, so nothing goes, whatever the reason; the phone keeps
    /// its requests and their delivered pushes. The snapshot that loads the view sends its set.
    @Test func anUnloadedEmptyViewAfterAFailedFirstConnectionSendsNothing() throws {
        func view(_ json: String) throws -> FeedDaemonView {
            try JSONDecoder().decode(FeedDaemonView.self, from: Data(json.utf8))
        }
        for reason in ["offline", "unavailable", "expired", "forbidden", "unauthenticated"] {
            let failed = try view(#"{"account":{"id":"stack:p:a","user":"a"},"revision":3,"loaded":false,"connection":{"state":"disconnected","reason":"\#(reason)"},"groups":[{"id":"needs_you","entries":[]}],"total":0}"#)
            #expect(!failed.isSettled, "\(reason)")
            #expect(FeedNeedsYouPhone.current(failed) == nil, "\(reason)")
        }
        let open = try item("fi_open")
        let loaded = try view(#"""
        {"account":{"id":"stack:p:a","user":"a"},"revision":5,"loaded":true,"connection":{"state":"connected"},"total":1,
         "groups":[{"id":"needs_you","entries":[{"id":"fi_open","item":{"id":"fi_open","home":"local:github","type":"request","kind":"review",
         "title":"GitHub","body":"acme/app#30817","context":{"url":"https://github.com/acme/app/pull/30817"},
         "poster":{"kind":"integration","label":"GitHub"},"state":"open","created_at":1700000000000,"github":null}}]}]}
        """#)
        #expect(FeedNeedsYouPhone.current(loaded) == FeedNeedsYouPhone.requests([open]))
        #expect(FeedNeedsYouPhone.current(loaded)?.map(\.id) == ["fi_open"])
    }

    static func view(_ json: String) throws -> FeedDaemonView {
        try JSONDecoder().decode(FeedDaemonView.self, from: Data(json.utf8))
    }

    /// A Needs you view of `account` (`loaded`, `state`, `reason`) holding `ids`' open requests.
    func needsYou(_ account: String?, loaded: Bool, state: String, reason: String? = nil, ids: [String] = []) throws -> FeedDaemonView {
        let accountJSON = account.map { #"{"id":"stack:proj:\#($0)","user":"\#($0)"}"# } ?? "null"
        let reasonJSON = reason.map { #","reason":"\#($0)""# } ?? ""
        let entries = ids.map { id in
            #"{"id":"\#(id)","item":{"id":"\#(id)","home":"cloud","type":"request","kind":"question","title":"\#(id) secret","body":"body of \#(id)","context":{"url":"https://example.com/\#(id)"},"poster":{"kind":"agent","label":"Agent"},"state":"open","created_at":1700000000000}}"#
        }.joined(separator: ",")
        return try Self.view(#"{"loaded":\#(loaded),"account":\#(accountJSON),"connection":{"state":"\#(state)"\#(reasonJSON)},"groups":[{"id":"needs_you","entries":[\#(entries)]}]}"#)
    }

    /// Account A's requests never reach account B's phones (manaflow-ai/cmux#37378 review): A loaded,
    /// then B connecting (unloaded) and B's connection failing. The projection forgets A's set at
    /// B's first view, sends nothing (an empty set would close requests), and a hostd started for B
    /// gets none of A's requests.
    @Test func anotherAccountsViewForgetsTheSetAndANewHostOfItGetsNone() async throws {
        var projection = FeedAccountProjection<[MobileHostNeedsYouRequest]>()
        let supervisor = MobileHostSupervisor()
        func run(_ view: FeedDaemonView) async -> [FeedAccountProjection<[MobileHostNeedsYouRequest]>.Step] {
            let steps = projection.phone(view)
            for step in steps {
                switch step {
                case .forget: await supervisor.clearNeedsYou()
                case let .send(set, user): await supervisor.setNeedsYou(set, user: user)
                }
            }
            return steps
        }
        let aSteps = await run(try needsYou("user_a", loaded: true, state: "connected", ids: ["fi_a"]))
        #expect(aSteps.count == 1)
        #expect(await supervisor.needsYouForHostd(user: "user_a") != nil)
        let steps1 = await run(try needsYou("user_b", loaded: false, state: "connecting"))
        #expect(steps1 == [.forget])
        #expect(projection.sent == nil)
        #expect(projection.account == "stack:proj:user_b")
        let steps2 = await run(try needsYou("user_b", loaded: false, state: "disconnected", reason: "unavailable"))
        #expect(steps2 == [])
        let steps3 = await run(try needsYou("user_b", loaded: false, state: "disconnected", reason: "offline"))
        #expect(steps3 == [])
        #expect(projection.sent == nil)
        // A hostd launched now, for B (or even A again), is handed no needs_you line at all.
        #expect(await supervisor.needsYouForHostd(user: "user_b") == nil)
        #expect(await supervisor.needsYouForHostd(user: "user_a") == nil)
        // B's own snapshot then goes to B's hostd only.
        let bSteps = await run(try needsYou("user_b", loaded: true, state: "connected", ids: ["fi_b"]))
        #expect(bSteps == [.send(FeedNeedsYouPhone.requests(try needsYou("user_b", loaded: true, state: "connected", ids: ["fi_b"]).items(in: "needs_you")), user: "user_b")])
        let line = try #require(await supervisor.needsYouForHostd(user: "user_b"))
        let text = String(decoding: line, as: UTF8.self)
        #expect(text.contains("fi_b") && !text.contains("fi_a"), "\(text)")
        #expect(await supervisor.needsYouForHostd(user: "user_a") == nil)
    }

    /// The supervisor keeps a set for its own account's hostd only, whatever order the calls come in.
    @Test func theSupervisorHandsASetOnlyToItsAccountsHost() async throws {
        let supervisor = MobileHostSupervisor()
        let set = FeedNeedsYouPhone.requests(try needsYou("user_a", loaded: true, state: "connected", ids: ["fi_a"]).items(in: "needs_you"))
        await supervisor.setNeedsYou(set, user: "user_a")
        #expect(await supervisor.needsYouForHostd(user: "user_a") == MobileHostLaunch.needsYouLine(set))
        #expect(await supervisor.needsYouForHostd(user: "user_b") == nil)
        await supervisor.clearNeedsYou()
        #expect(await supervisor.needsYouForHostd(user: "user_a") == nil)
    }

    /// Signed out: the set is forgotten, and nothing is sent.
    @Test func signingOutForgetsTheSet() throws {
        var projection = FeedAccountProjection<[MobileHostNeedsYouRequest]>()
        let steps4 = projection.phone(try needsYou("user_a", loaded: true, state: "connected", ids: ["fi_a"]))
        #expect(steps4.count == 1)
        let steps5 = projection.phone(try needsYou(nil, loaded: false, state: "disconnected", reason: "signed_out"))
        #expect(steps5 == [.forget])
        #expect(projection.sent == nil && projection.account == nil)
    }

    /// A disconnect of the same account keeps the set: reconnecting (unsettled) changes nothing, and
    /// offline once loaded the mirror kept the cloud requests, so the same set is not sent again.
    @Test func aDisconnectOfTheSameAccountKeepsTheSet() throws {
        var projection = FeedAccountProjection<[MobileHostNeedsYouRequest]>()
        let loaded = try needsYou("user_a", loaded: true, state: "connected", ids: ["fi_a"])
        let steps6 = projection.phone(loaded)
        #expect(steps6.count == 1)
        let kept = projection.sent
        #expect(kept?.map(\.id) == ["fi_a"])
        let steps7 = projection.phone(try needsYou("user_a", loaded: true, state: "connecting", ids: ["fi_a"]))
        #expect(steps7 == [])
        let steps8 = projection.phone(try needsYou("user_a", loaded: true, state: "disconnected", reason: "offline", ids: ["fi_a"]))
        #expect(steps8 == [])
        #expect(projection.sent == kept)
        #expect(projection.account == "stack:proj:user_a")
    }
}

/// The phone's projection as `FeedNeedsYouPhone.follow` runs it.
extension FeedAccountProjection where Value == [MobileHostNeedsYouRequest] {
    @MainActor mutating func phone(_ view: FeedDaemonView) -> [Step] {
        apply(view, derive: { FeedNeedsYouPhone.current($0) })
    }
}
