import AppKit
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// A chat handed off to a Cloud machine is followed by the app-level waiter on the hand-off store's
/// `/wait` (``SandboxRunFollower`` with ``SandboxRunFollower/Source/handoffs(wait:)``). The follower's
/// rules and their cases are Rust's (cmux-tui/crates/cmux-cloud-tasks); these cases cover
/// ``HandoffNotices``: its banner, its list call and what it hands the follower.
@Suite(.serialized)
@MainActor
struct HandoffNoticeTests {
    /// The store's `/wait`, scripted per hand-off: each call takes the next answer, the last repeats.
    actor Store {
        var answers: [String: [Result<String, CloudAPIError>]] = [:]
        private(set) var afters: [Int?] = []

        func script(_ id: String, _ answers: [Result<String, CloudAPIError>]) { self.answers[id] = answers }

        func wait(_ id: String, after: Int?) throws -> Data {
            afters.append(after)
            guard var queue = answers[id], let first = queue.first else { throw CloudAPIError.http(status: 404, code: nil, message: nil) }
            if queue.count > 1 { queue.removeFirst(); answers[id] = queue }
            return Data(try first.get().utf8)
        }
    }

    static let id = "ho_0123456789abcdef0123"

    /// A `{handoff}` answer; `turn` and `state` nil leave them out (the store before turns).
    static func handoff(_ status: String, version: Int, turn: Int? = 1, state: String? = "open", summary: String? = nil,
                        id: String = id) -> Result<String, CloudAPIError> {
        var handoff: [String: Any] = ["id": id, "sessionId": "s1", "status": status, "version": version, "summary": summary ?? NSNull()]
        if let turn { handoff["turn"] = turn }
        if let state { handoff["state"] = state }
        return .success(String(decoding: (try? JSONSerialization.data(withJSONObject: ["handoff": handoff])) ?? Data(), as: UTF8.self))
    }

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "HandoffNoticeTests.\(UUID().uuidString)"))
    }

    private func follower(_ store: Store, defaults: UserDefaults) -> (SandboxRunFollower, SandboxRunNoticeTests.Ends) {
        let follower = SandboxRunFollower(source: .handoffs(wait: { id, after in try await store.wait(id, after: after) }),
                                          defaults: defaults, clock: ImmediateRunClock())
        let ends = SandboxRunNoticeTests.Ends()
        follower.onEnd = { ends.add($0) }
        follower.account("u1")
        return (follower, ends)
    }

    private static func listEntry(status: String = "starting", version: Int? = nil, turn: Int? = nil, id: String = id,
                                  state: String = "open") -> CloudHandoff {
        CloudHandoff(id: id, sessionId: "s1", status: status, summary: nil, createdAt: Date().timeIntervalSince1970 * 1_000,
                     version: version, turn: turn, state: state)
    }

    private func record(_ id: String = Self.id) -> SandboxRunRecord { HandoffNotices.record(Self.listEntry(id: id), user: "u1", host: nil) }

    private func settle(_ follower: SandboxRunFollower) async {
        while follower.isPolling(Self.id) { await Task.yield() }
    }

    @Test func theBannerNamesTheChatThenWhatHappened() throws {
        let done = try SandboxRunEnd(record: record(), outcome: .succeeded, snapshot: Data(Self.handoff("done", version: 6, summary: "Fixed the flaky test").get().utf8))
        let named = HandoffNotices.text(done, chat: "Flaky test")
        #expect(named.title == "Flaky test")
        #expect(named.body == "Done\nFixed the flaky test")
        // No chat title: the summary's first line is the title.
        let unnamed = HandoffNotices.text(done, chat: nil)
        #expect(unnamed.title == "Fixed the flaky test")
        #expect(unnamed.body == "Done")
        let waiting = try SandboxRunEnd(record: record(), outcome: .needsYou, snapshot: Data(Self.handoff("needs-you", version: 3).get().utf8))
        #expect(HandoffNotices.text(waiting, chat: nil) == (title: "Cloud task", body: "Needs you"))
        #expect(HandoffNotices.text(waiting, chat: "  ").title == "Cloud task")
    }

    @Test func theListsTimesAreReadAsTheStoreSendsThem() throws {
        struct Page: Decodable { var handoffs: [CloudHandoff] }
        let body = #"{"handoffs":[{"id":"ho_0123456789abcdef0123","sessionId":"s1","turn":2,"state":"open","status":"running","summary":null,"#
            + #""createdAt":"2026-10-20T10:00:00.000Z","updatedAt":"2026-10-28T09:30:00.250Z"},"#
            + #"{"id":"ho_0123456789abcdef0124","sessionId":"s2","status":"done","summary":"x","createdAt":1792490400000}],"nextCursor":null}"#
        let page = try JSONDecoder().decode(Page.self, from: Data(body.utf8))
        let listed = try #require(page.handoffs.first)
        #expect(abs(listed.createdAt - 1_792_490_400_000) < 1)
        #expect(abs((listed.updatedAt ?? 0) - 1_793_179_800_250) < 1)
        #expect(listed.isRunning && listed.isOpen && listed.version == nil)
        let record = HandoffNotices.listed(listed, user: "u1")
        #expect(abs((record.changed?.timeIntervalSince1970 ?? 0) - 1_793_179_800.25) < 0.001)
        #expect(record.running == true)
        #expect(page.handoffs.last?.createdAt == 1_792_490_400_000)
        #expect(page.handoffs.last?.updatedAt == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Page.self, from: Data(#"{"handoffs":[{"id":"a","sessionId":"s","status":"done","createdAt":"yesterday"}]}"#.utf8))
        }
    }

    /// A list call held until the test answers it.
    actor HeldList {
        private var answer: CheckedContinuation<[CloudHandoff], Never>?
        private var callers: [CheckedContinuation<Void, Never>] = []
        private var calls = 0

        func list() async -> [CloudHandoff] {
            calls += 1
            for caller in callers { caller.resume() }
            callers = []
            return await withCheckedContinuation { answer = $0 }
        }

        /// Returns once the list was called.
        func called() async {
            if calls > 0 { return }
            await withCheckedContinuation { callers.append($0) }
        }

        func respond(_ handoffs: [CloudHandoff]) {
            answer?.resume(returning: handoffs)
            answer = nil
        }
    }

    @MainActor final class Account { var user: String? = "u1" }
    private static var kept: [AppServices] = []

    private func notices(_ held: HeldList, _ account: Account, store: Store, defaults: UserDefaults? = nil) throws -> (HandoffNotices, SandboxRunFollower) {
        let (follower, _) = follower(store, defaults: try defaults ?? self.defaults())
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        Self.kept.append(services) // HandoffNotices holds its services weakly
        let notices = HandoffNotices(services: services, follower: follower, list: { await held.list() }, user: { account.user })
        return (notices, follower)
    }

    @Test func aSignOutEndsTheListCallAndItsLateAnswerFollowsNothing() async throws {
        let store = Store(), held = HeldList(), account = Account()
        await store.script(Self.id, [Self.handoff("running", version: 2)])
        let (notices, follower) = try notices(held, account, store: store)
        notices.followAccount("u1")
        await held.called()
        let call = try #require(notices.listing)
        account.user = nil
        notices.followAccount(nil)
        #expect(call.isCancelled)
        #expect(notices.listing == nil)
        await held.respond([Self.listEntry(status: "running")])
        await call.value
        #expect(!follower.knows(Self.id))
        #expect(!follower.isPolling(Self.id))
        #expect(await store.afters.isEmpty)
    }

    @Test func aListAnsweredAfterCloudWentOffOrAnotherUserSignedInFollowsNothing() async throws {
        for later in [nil, "u2"] as [String?] {
            let store = Store(), held = HeldList(), account = Account()
            await store.script(Self.id, [Self.handoff("running", version: 2)])
            let (notices, follower) = try notices(held, account, store: store)
            notices.followAccount("u1")
            await held.called()
            let call = try #require(notices.listing)
            // The account changed, and its observer has not run yet.
            account.user = later
            await held.respond([Self.listEntry(status: "running")])
            await call.value
            #expect(!follower.knows(Self.id), "user \(later ?? "none")")
            #expect(await store.afters.isEmpty)
            notices.stop()
        }
    }

    @Test func aListAnsweredForTheSameUserIsFollowed() async throws {
        let store = Store(), held = HeldList(), account = Account()
        await store.script(Self.id, [Self.handoff("running", version: 2), .failure(.http(status: 404, code: nil, message: nil))])
        let (notices, follower) = try notices(held, account, store: store)
        notices.followAccount("u1")
        await held.called()
        let call = try #require(notices.listing)
        await held.respond([Self.listEntry(status: "running")])
        await call.value
        await settle(follower)
        #expect(await store.afters == [nil, 2])
        notices.stop()
    }

    /// Issue #31208: an incognito hand-off that closed while the app was stopped is never resumed (its
    /// record isn't saved), so nothing removed its id. Once the signed-in list answers, an id of that user
    /// neither followed nor open in the list is dropped; one open in the list, one followed by this launch,
    /// and another account's stay.
    @Test func incognitoIDsNeitherFollowedNorListedAreDroppedOnceTheListAnswers() async throws {
        let (gone, listed, followed) = ("ho_0123456789abcdef0124", "ho_0123456789abcdef0125", "ho_0123456789abcdef0126")
        let (closed, other) = ("ho_0123456789abcdef0127", "ho_0123456789abcdef0128")
        let store = Store()
        for id in [gone, listed, followed, closed, other] { await store.script(id, [Self.handoff("running", version: 2, id: id)]) }
        let defaults = try defaults()
        let (first, _) = follower(store, defaults: defaults)
        // Another account's open incognito hand-off, made before u1 signed in.
        first.account("u2")
        var theirs = record(other)
        (theirs.user, theirs.incognito) = ("u2", true)
        first.watch(theirs)
        first.account("u1")
        for id in [gone, listed, followed, closed] {
            var incognito = record(id)
            incognito.incognito = true
            first.watch(incognito)
        }
        first.stop()
        func saved() -> String { String(decoding: defaults.data(forKey: SandboxRunFollower.Source.handoffsKey) ?? Data(), as: UTF8.self) }
        #expect([gone, listed, followed, closed, other].allSatisfy { saved().contains($0) })
        // The relaunch: this app watches `followed` again before the list answers; `gone` and `closed` closed while it was stopped.
        let held = HeldList(), account = Account()
        let (notices, relaunched) = try notices(held, account, store: store, defaults: defaults)
        notices.followAccount("u1")
        await held.called()
        let call = try #require(notices.listing)
        var again = record(followed)
        again.incognito = true
        relaunched.watch(again)
        await held.respond([Self.listEntry(status: "running", version: 2, turn: 1, id: listed),
                            Self.listEntry(status: "done", version: 3, turn: 1, id: closed, state: "closed")])
        await call.value
        #expect(!saved().contains(gone), "an incognito hand-off that ended while the app was stopped kept its id")
        #expect(!saved().contains(closed), "a closed incognito hand-off in the list kept its id")
        #expect(saved().contains(listed) && saved().contains(followed))
        #expect(saved().contains(other), "another account's list took its incognito hand-off's flag away")
        #expect(relaunched.following.filter { $0.incognito == true }.map(\.id).sorted() == [listed, followed])
        notices.stop()
    }

    @Test func onlyStoreIDsReachThePath() {
        #expect(CloudOwnerAPIClient.isHandoffID(Self.id))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_../../v1/cloud"))
        #expect(!CloudOwnerAPIClient.isHandoffID("ho_0123456789ABCDEF0123"))
    }
}
