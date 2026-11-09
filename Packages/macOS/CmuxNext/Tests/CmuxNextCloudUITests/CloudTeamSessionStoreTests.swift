import CmuxNextActions
import CmuxNextCloudUI
import Foundation
import Testing

/// The Team section's core (lane D): TeamDO's `team.cloud.session.*` replies become the shown rows
/// under the filter, a Follow / Reassign / Archive changes the row on the same turn and rolls back on a
/// refusal with TeamDO's code, a stale list is dropped, and the publisher sends only what changed.
@MainActor @Suite struct CloudTeamSessionStoreTests {
    static let team = "team_0123456789abcdefghij"

    /// A scripted Worker: each call answers the next reply (or throws it) and is recorded.
    final class FakeWorker {
        var calls: [(path: String, body: [String: Any], team: String?)] = []
        var replies: [Result<[String: Any], CloudTeamError>] = []
        /// When set, each call waits until the test releases it; its reply is the one queued when it started.
        var holds = false
        var waiting: [CheckedContinuation<Void, Never>] = []

        var transport: CloudTeamSessionStore.Transport {
            { [self] path, body, team in
                calls.append((path, body, team))
                let reply = replies.isEmpty ? .success(["value": [String: Any]()]) : replies.removeFirst()
                if holds { await withCheckedContinuation { waiting.append($0) } }
                return try reply.get()
            }
        }

        /// Lets the `index`th held call (in the order they started) answer.
        func release(_ index: Int = 0) {
            waiting.remove(at: index).resume()
        }

        /// Yields until `count` calls are held.
        func held(_ count: Int) async {
            while waiting.count < count { await Task.yield() }
        }
    }

    static func row(_ id: String, at: Int = 1, mine: Bool = false, following: Bool = false, archived: Bool = false,
                    assignee: String = "user_b", followers: Int = 0) -> [String: Any] {
        ["key": "cloud:\(team)/vm_a/\(id)", "team": team, "vm": "vm_a", "session": id, "kind": "chat", "title": "Chat \(id)",
         "owner": "user_a", "owner_name": "Ann", "assignee": assignee, "assignee_name": NSNull(), "machine_state": "running",
         "activity": "idle", "last_activity_at": at, "created_at": 1, "archived": archived, "followers": [String](),
         "follower_count": followers, "following": following, "assigned_to_you": mine, "viewers": [String](),
         "can_reassign": true, "can_archive": true, "link": "cmux://cloud/session/\(team)/vm_a/\(id)"]
    }

    static func list(_ rows: [[String: Any]]) -> [String: Any] {
        ["value": ["team": team, "sessions": rows, "next_cursor": NSNull()]]
    }

    static func ref(_ id: String) -> CloudTeamSessionStore.Ref { .init(team: team, vm: "vm_a", session: id) }

    @Test func aKeyOrALinkNamesASessionAndAnythingElseDoesNot() throws {
        let key = try #require(CloudTeamSessionStore.Ref("cloud:\(Self.team)/vm_a/s1"))
        #expect(key == .init(team: Self.team, vm: "vm_a", session: "s1", kind: .chat))
        let link = try #require(CloudTeamSessionStore.Ref("cmux://cloud/workspace/\(Self.team)/vm_a/ws_1"))
        #expect(link.kind == .workspace && link.key == "cloud:\(Self.team)/vm_a/ws_1")
        #expect(CloudTeamSessionStore.Ref("cloud:team_x/vm_a/s1") == nil)
        #expect(CloudTeamSessionStore.Ref("https://example.com/cloud/session") == nil)
    }

    @Test func theShownListKeepsOnlyRowsOfItsFilterAndSendsTheTeamHeader() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport, activeTeam: { Self.team })
        worker.replies = [.success(Self.list([Self.row("s1", at: 5, mine: true), Self.row("s2", at: 4)]))]
        await store.refresh()
        #expect(store.sessions.map(\.session) == ["s1"], "Assigned to Me shows only the caller's")
        let body = worker.calls[0].body
        #expect(worker.calls[0].path == "v1/read" && body["op"] as? String == "team.cloud.session.list")
        #expect((body["params"] as? [String: Any])?["scope"] as? String == "mine")
        #expect(worker.calls[0].team == Self.team, "the active team in x-cmux-team, not the Worker's personal default")
        worker.replies = [.success(["value": ["team": Self.team, "members": [[String: Any]](), "member_count": 0, "next_cursor": NSNull(), "revision": "1"]]),
                          .success(["value": ["group": "grp_1", "members": [[String: Any]]()]])]
        _ = try await store.loadMembers()
        _ = try await store.groupMembers("grp_1")
        #expect(worker.calls[1].team == Self.team && worker.calls[2].team == Self.team)
        // A script's page with `by` never replaces what the section shows.
        worker.replies = [.success(Self.list([Self.row("s9")]))]
        _ = try await store.list(scope: "mine", by: "user_b")
        #expect(store.sessions.map(\.session) == ["s1"])
        #expect(worker.calls.last?.team == Self.team)
        // A link's own team goes in x-cmux-team.
        worker.replies = [.success(["value": ["session": Self.row("s1", mine: true)]])]
        _ = try await store.get(Self.ref("s1"))
        #expect(worker.calls.last?.team == Self.team)
    }

    @Test func aListThatAnswersAfterTheFilterChangedIsDropped() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.holds = true
        worker.replies = [.success(Self.list([Self.row("old", mine: true)])), .success(Self.list([Self.row("new")]))]
        // task-owner: the test's first list, released after the filter changed.
        let first = Task { await store.refresh() }
        await worker.held(1)
        // task-owner: the test's second list.
        let second = Task { await store.select(.team) }
        await worker.held(2)
        worker.release(1)
        await second.value
        worker.release(0)
        await first.value
        #expect(store.filter == .team)
        #expect(store.sessions.map(\.session) == ["new"], "the Assigned to Me reply came after Team was picked")
    }

    @Test func followShowsAtOnceAndARefusalRollsBackWithItsCode() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.replies = [.success(Self.list([Self.row("s1")]))]
        await store.select(.team)
        worker.holds = true
        worker.replies = [.success(["_tag": "Refused", "code": "cloud_session.assigned_to_you", "message": "yours"])]
        // task-owner: the test's follow, held until checked.
        let follow = Task { _ = try await store.setFollowing(Self.ref("s1"), true) }
        await worker.held(1)
        #expect(store.row(Self.ref("s1"))?.following == true, "the eye fills on the click's turn")
        #expect(store.row(Self.ref("s1"))?.followerCount == 1)
        worker.release()
        await #expect(throws: CloudTeamError(code: "cloud_session.assigned_to_you", message: "yours")) { try await follow.value }
        #expect(store.row(Self.ref("s1"))?.following == false && store.row(Self.ref("s1"))?.followerCount == 0)
        let body = try #require(worker.calls.last?.body)
        #expect(worker.calls.last?.path == "v1/ops" && body["origin"] as? String == "user" && body["idempotency_key"] is String)
        #expect((body["params"] as? [String: Any])?["follow"] as? Bool == true)
    }

    @Test func unfollowUnderFollowingTakesTheRowOutAndARefusalPutsItBack() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.replies = [.success(Self.list([Self.row("s1", at: 3, following: true, followers: 1), Self.row("s2", at: 2, following: true)]))]
        await store.select(.following)
        worker.replies = [.failure(CloudTeamError(code: CloudTeamError.unreachable, message: "down"))]
        await #expect(throws: CloudTeamError.self) { try await store.setFollowing(Self.ref("s1"), false) }
        #expect(store.sessions.map(\.session) == ["s1", "s2"], "back in its place by activity")
        worker.replies = [.success(["value": Self.row("s1", at: 3, following: false)])]
        _ = try await store.setFollowing(Self.ref("s1"), false)
        #expect(store.sessions.map(\.session) == ["s2"])
    }

    @Test func reassigningMyWorkAwayLeavesAssignedToMeAndIFollowIt() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport, currentUser: { "user_me" })
        worker.replies = [.success(Self.list([Self.row("s1", mine: true, assignee: "user_me")]))]
        await store.refresh()
        worker.holds = true
        // task-owner: the test's reassign, held until checked.
        let reassign = Task { _ = try await store.reassign(Self.ref("s1"), to: "user_b") }
        await worker.held(1)
        #expect(store.sessions.isEmpty, "no longer assigned to me, on the click's turn")
        worker.release()
        _ = try await reassign.value
        #expect((worker.calls[1].body["params"] as? [String: Any])?["to"] as? String == "user_b")
        // TeamDO refuses a guest: the row comes back under Assigned to Me.
        worker.holds = false
        worker.replies = [.success(Self.list([Self.row("s1", mine: true, assignee: "user_me")]))]
        await store.refresh()
        worker.replies = [.failure(CloudTeamError(code: "cloud_session.assignee_not_member", message: "guest"))]
        await #expect(throws: CloudTeamError(code: "cloud_session.assignee_not_member", message: "guest")) {
            try await store.reassign(Self.ref("s1"), to: "user_guest")
        }
        #expect(store.sessions.map(\.session) == ["s1"])
    }

    @Test func archiveMovesARowOutOfTeamIntoArchived() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.replies = [.success(Self.list([Self.row("s1")]))]
        await store.select(.team)
        worker.replies = [.success(["value": Self.row("s1", archived: true)])]
        _ = try await store.setArchived(Self.ref("s1"), true)
        #expect(store.sessions.isEmpty)
        worker.replies = [.success(Self.list([Self.row("s1", archived: true)]))]
        await store.select(.archived)
        #expect(store.sessions.map(\.session) == ["s1"])
        let params = try #require(worker.calls.last?.body["params"] as? [String: Any])
        #expect(params["scope"] as? String == "team" && params["archived"] as? Bool == true)
    }

    @Test func aWorkerErrorObjectIsItsCodeAndAFailedListKeepsTheRows() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.replies = [.success(Self.list([Self.row("s1")]))]
        await store.select(.team)
        worker.replies = [.success(["error": ["code": "team.not_member", "message": "removed"]])]
        await store.refresh()
        #expect(store.listError?.code == "team.not_member")
        #expect(store.sessions.map(\.session) == ["s1"])
    }

    @Test func aScriptsPageDoesNotDropTheSectionsListOrLeaveItLoading() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport, activeTeam: { Self.team })
        worker.holds = true
        worker.replies = [.success(Self.list([Self.row("s1", mine: true)])), .success(Self.list([Self.row("s9")]))]
        // task-owner: the section's list, held while a script pages.
        let section = Task { await store.refresh() }
        await worker.held(1)
        #expect(store.isLoading)
        // task-owner: a script's `--by` page.
        let script = Task { _ = try await store.list(scope: "mine", by: "user_b") }
        await worker.held(2)
        worker.release(1)
        _ = try await script.value
        worker.release(0)
        await section.value
        #expect(store.sessions.map(\.session) == ["s1"], "the section's reply still lands")
        #expect(!store.isLoading)
    }

    @Test func aFailedListThatAnOlderOneRacesKeepsTheNewerAnswer() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.holds = true
        worker.replies = [.failure(CloudTeamError(code: CloudTeamError.unreachable, message: "down")), .success(Self.list([Self.row("s2")]))]
        // task-owner: the test's first list, which fails after the filter changed.
        let first = Task { await store.refresh() }
        await worker.held(1)
        // task-owner: the test's second list.
        let second = Task { await store.select(.team) }
        await worker.held(2)
        worker.release(1)
        await second.value
        worker.release(0)
        await first.value
        #expect(store.listError == nil, "an older list's failure does not show over the newer answer")
        #expect(store.sessions.map(\.session) == ["s2"])
    }

    @Test func aRefusalDoesNotUndoARowALaterListReplaced() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.replies = [.success(Self.list([Self.row("s1")]))]
        await store.select(.team)
        worker.holds = true
        worker.replies = [.failure(CloudTeamError(code: "cloud_session.not_found", message: "gone")),
                          .success(Self.list([Self.row("s1", following: true, followers: 3)]))]
        // task-owner: the test's follow, refused after a list replaced the row.
        let follow = Task { _ = try await store.setFollowing(Self.ref("s1"), true) }
        await worker.held(1)
        // task-owner: the list that lands first.
        let list = Task { await store.refresh() }
        await worker.held(2)
        worker.release(1)
        await list.value
        worker.release(0)
        await #expect(throws: CloudTeamError.self) { try await follow.value }
        #expect(store.row(Self.ref("s1"))?.followerCount == 3, "the list's row stays")
    }

    @Test func aTeamSwitchDropsTheOldTeamsRowsAndItsInFlightList() async throws {
        let worker = FakeWorker()
        var active = Self.team
        let store = CloudTeamSessionStore(transport: worker.transport, activeTeam: { active })
        store.setTeam(active)
        worker.replies = [.success(Self.list([Self.row("s1")]))]
        await store.select(.team)
        worker.holds = true
        worker.replies = [.success(Self.list([Self.row("old")]))]
        // task-owner: the old team's list, answered after the switch.
        let stale = Task { await store.refresh() }
        await worker.held(1)
        active = "team_zzzzzzzzzzzzzzzzzzzz"
        store.setTeam(active)
        #expect(store.sessions.isEmpty && store.team == active)
        worker.release()
        await stale.value
        #expect(store.sessions.isEmpty, "the old team's reply does not show under the new team")
        #expect(!store.isLoading)
    }

    @Test func guestsAndBillingMembersAreNotReassignTargets() {
        #expect(CloudTeamMember(user: "u", name: "n", role: "member").canBeAssigned)
        #expect(CloudTeamMember(user: "u", name: "n", role: "admin").canBeAssigned)
        #expect(!CloudTeamMember(user: "u", name: "n", role: "guest").canBeAssigned)
        #expect(!CloudTeamMember(user: "u", name: "n", role: "billing").canBeAssigned)
    }

    @Test func publishSendsWhatTeamDOTakes() async throws {
        let worker = FakeWorker()
        let store = CloudTeamSessionStore(transport: worker.transport)
        worker.replies = [.success(["value": Self.row("s1")])]
        let long = String(repeating: "é", count: 150) + String(repeating: "😀", count: 40)
        _ = try await store.publish(Self.ref("s1"), title: long, workspace: "ws_1", harness: "Claude Code", machineState: "running",
                                    activity: "working", lastActivityAt: 42)
        let body = try #require(worker.calls.last?.body)
        let params = try #require(body["params"] as? [String: Any])
        #expect(body["op"] as? String == "team.cloud.session.publish" && worker.calls.last?.team == Self.team)
        #expect(params["kind"] as? String == "chat" && params["workspace"] as? String == "ws_1")
        #expect(params["harness"] == nil, "not a harness name TeamDO takes")
        #expect(((params["title"] as? String)?.utf16.count ?? 999) <= 200)
        #expect(params["last_activity_at"] as? Int == 42)
    }

    @Test func thePublishPlanSendsOnlyChanges() {
        var plan = CloudTeamPublishPlan()
        let input = CloudTeamPublishInput(ref: Self.ref("s1"), title: "t", workspace: nil, harness: "claude", machineState: "running", activity: "idle")
        #expect(plan.changes([input], now: 10).map { $0.1 } == [10])
        #expect(plan.changes([input], now: 20).isEmpty, "nothing changed")
        var renamed = input
        renamed.title = "t2"
        #expect(plan.changes([renamed], now: 30).map { $0.1 } == [10], "a rename keeps the activity's time")
        var working = renamed
        working.activity = "working"
        #expect(plan.changes([working], now: 40).map { $0.1 } == [40])
        plan.forget(input.ref.key)
        #expect(plan.changes([working], now: 50).count == 1, "a refused publish is sent again")
    }

    @Test func activityAndMachineStateMapToTeamDOValues() {
        #expect(CloudTeamPublishInput.activity(agentState: "working", attention: false) == "working")
        #expect(CloudTeamPublishInput.activity(agentState: "blocked", attention: false) == "needs_attention")
        #expect(CloudTeamPublishInput.activity(agentState: "idle", attention: true) == "needs_attention")
        #expect(CloudTeamPublishInput.activity(agentState: nil, attention: false) == "idle")
        #expect(CloudTeamPublishInput.machineState(status: "running", connected: true) == "running")
        #expect(CloudTeamPublishInput.machineState(status: "running", connected: false) == "unresponsive")
        #expect(CloudTeamPublishInput.machineState(status: "paused", connected: false) == "asleep")
        #expect(CloudTeamPublishInput.machineState(status: "starting", connected: false) == "waking")
        #expect(CloudTeamPublishInput.machineState(status: "destroyed", connected: false) == "gone")
    }
}
