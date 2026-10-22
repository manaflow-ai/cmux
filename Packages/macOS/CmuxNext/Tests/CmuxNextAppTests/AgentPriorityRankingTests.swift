import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextSidebar
import Foundation
import Testing

/// The sidebar's Priority view sifts what needs the person to the top (Leo 2026-10-20: Codex's
/// Priority list "doesn't even do that"): a question or permission prompt first, then a finished
/// result nobody has seen, then a failed or lost turn, then the working ones, then idle; within a
/// tier pinned first, then the most recent. Read and snooze marks hold until the chat moves on.
@MainActor
struct AgentPriorityRankingTests {
    static let now = Date(timeIntervalSince1970: 1_760_000_000)

    static func lane(_ id: String, _ state: AgentActivityLane.State, ago minutes: Double, unread: Bool = false,
                     peer: String? = nil, error: String? = nil, step: String? = nil) -> AgentActivityLane {
        AgentActivityLane(id: id, name: id, title: id, peer: peer, parent: nil, state: state,
                          since: now.addingTimeInterval(-minutes * 60), error: error, step: step, unread: unread, project: "cmux")
    }

    static let lanes = [
        lane("idle-old", .idle, ago: 30),
        lane("working", .working, ago: 5, step: "Running tests"),
        lane("done", .idle, ago: 20, unread: true),
        lane("asks", .input, ago: 50, peer: "mini"),
        lane("broke", .failed, ago: 10, error: "Credit balance too low"),
        lane("asks-new", .input, ago: 1),
        lane("idle-new", .idle, ago: 2),
    ]

    @Test func needsYouThenUnseenResultsThenFailuresThenWorkingThenIdle() {
        let entries = AgentPriorityRanking().entries(Self.lanes, marks: .init(), now: Self.now)
        #expect(entries.map(\.id) == ["asks-new", "asks", "done", "broke", "working", "idle-new", "idle-old"])
        #expect(entries[0].state == .needsYou)
        #expect(entries[1].machine == "mini")
        #expect(entries[2].state == .done && entries[2].unread)
        #expect(entries[3].state == .failed && entries[3].preview == "Credit balance too low")
        #expect(entries[4].preview == "Running tests")
        #expect(SidebarPriorityPanel(entries: entries).attentionCount == 4)
    }

    /// A chat whose pull request's checks fail (the session tree's PR badge reads red) ranks as Red
    /// CI: after a finished result nobody has seen and a failed turn, before the working ones. A
    /// question or an unseen result outranks its red checks; read, the result leaves them showing.
    @Test func aChatWhosePullRequestChecksFailRanksAsRedCIBeforeWorking() {
        let red = Self.lane("red-ci", .idle, ago: 3), stale = Self.lane("red-stale", .idle, ago: 60 * 48)
        let ranking = AgentPriorityRanking()
        let entries = ranking.entries(Self.lanes + [red, stale], marks: .init(), now: Self.now, failingChecks: ["red-ci", "red-stale"])
        #expect(entries.map(\.id) == ["asks-new", "asks", "done", "broke", "red-ci", "red-stale", "working", "idle-new", "idle-old"])
        #expect(entries[4].state == .ciFailing && entries[4].needsAttention)
        #expect(ranking.nextChange([stale], marks: .init(), now: Self.now, failingChecks: ["red-stale"]) == nil)

        let overlapping: Set<String> = ["asks", "done", "working"]
        var states = Dictionary(uniqueKeysWithValues: ranking.entries(Self.lanes, marks: .init(), now: Self.now,
                                                                      failingChecks: overlapping).map { ($0.id, $0.state) })
        #expect(states["asks"] == .needsYou && states["done"] == .done && states["working"] == .ciFailing)
        let marks = AgentPriorityMarks(defaults: nil)
        marks.markRead(Self.lane("done", .idle, ago: 20, unread: true))
        states = Dictionary(uniqueKeysWithValues: ranking.entries(Self.lanes, marks: marks.state, now: Self.now,
                                                                  failingChecks: overlapping).map { ($0.id, $0.state) })
        #expect(states["done"] == .ciFailing)
    }

    @Test func aPinnedChatLeadsItsTierAndStaysWhileIdleForLong() {
        let marks = AgentPriorityMarks(defaults: nil)
        let stale = Self.lane("stale", .idle, ago: 60 * 48)
        #expect(AgentPriorityRanking().entries([stale], marks: marks.state, now: Self.now).isEmpty)
        marks.togglePin("stale")
        marks.togglePin("idle-old")
        let entries = AgentPriorityRanking().entries(Self.lanes + [stale], marks: marks.state, now: Self.now)
        #expect(entries.suffix(3).map(\.id) == ["idle-old", "stale", "idle-new"])
        #expect(entries.first { $0.id == "stale" }?.pinned == true)
    }

    @Test func readAndSnoozeHoldUntilTheChatMovesOn() {
        let marks = AgentPriorityMarks(defaults: nil)
        let done = Self.lane("done", .idle, ago: 20, unread: true)
        marks.markRead(done)
        marks.snooze(Self.lane("asks", .input, ago: 50), now: Self.now)
        var entries = AgentPriorityRanking().entries(Self.lanes, marks: marks.state, now: Self.now)
        #expect(entries.first { $0.id == "done" }?.state == .idle)
        #expect(entries.first { $0.id == "done" }?.unread == false)
        #expect(!entries.contains { $0.id == "asks" })
        // A new question (a new state stamp) ends the snooze; so does the hour passing.
        let asksAgain = Self.lane("asks", .input, ago: 0)
        entries = AgentPriorityRanking().entries([asksAgain], marks: marks.state, now: Self.now)
        #expect(entries.map(\.id) == ["asks"])
        entries = AgentPriorityRanking().entries(Self.lanes, marks: marks.state, now: Self.now.addingTimeInterval(61 * 60))
        #expect(entries.contains { $0.id == "asks" })
    }

    @Test func archivedChatsLeaveAndMarksSurviveARelaunch() throws {
        let suite = "AgentPriorityRankingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let marks = AgentPriorityMarks(defaults: defaults)
        marks.archive("broke")
        marks.togglePin("working")
        marks.setCollapsed(true)
        let reloaded = AgentPriorityMarks(defaults: defaults)
        #expect(reloaded.state == marks.state)
        let entries = AgentPriorityRanking().entries(Self.lanes, marks: reloaded.state, now: Self.now)
        #expect(!entries.contains { $0.id == "broke" })
        reloaded.prune(keeping: ["working"])
        #expect(reloaded.state.archived.isEmpty && reloaded.state.pinned == ["working"])
    }

    @Test func theRowsWakeAtTheNextSnoozeEndOrIdleAgeOut() {
        let marks = AgentPriorityMarks(defaults: nil)
        let ranking = AgentPriorityRanking()
        // idle-old (30 min ago) leaves first: 23.5 hours from now.
        #expect(ranking.nextChange(Self.lanes, marks: marks.state, now: Self.now) == Self.now.addingTimeInterval(24 * 3600 - 30 * 60))
        marks.snooze(Self.lane("asks", .input, ago: 50), now: Self.now)
        #expect(ranking.nextChange(Self.lanes, marks: marks.state, now: Self.now) == Self.now.addingTimeInterval(3600))
        // Pinned or unseen chats never age out.
        let pinned = AgentPriorityMarks(defaults: nil)
        pinned.togglePin("idle-old")
        pinned.togglePin("idle-new")
        #expect(ranking.nextChange(Self.lanes, marks: pinned.state, now: Self.now) == nil)
        // A snooze on an older state of the chat, or an archived chat, changes no row.
        pinned.snooze(Self.lane("asks", .input, ago: 90), now: Self.now)
        #expect(ranking.nextChange(Self.lanes, marks: pinned.state, now: Self.now) == nil)
        pinned.togglePin("idle-old")
        pinned.archive("idle-old")
        #expect(ranking.nextChange(Self.lanes, marks: pinned.state, now: Self.now) == nil)
        marks.archive("broke")
        marks.unarchive("broke")
        #expect(ranking.entries(Self.lanes, marks: marks.state, now: Self.now).contains { $0.id == "broke" })
    }

    @Test func theBellDotShowsOnlyWhileTheRowsAreOutOfSight() {
        let entries = AgentPriorityRanking().entries(Self.lanes, marks: .init(), now: Self.now)
        #expect(!SidebarPriorityPanel(entries: entries, shown: true).bellDot)
        #expect(SidebarPriorityPanel(entries: entries, shown: true, collapsed: true).bellDot)
        #expect(SidebarPriorityPanel(entries: entries, shown: false).bellDot)
        #expect(!SidebarPriorityPanel(entries: entries.filter { !$0.needsAttention }, shown: false).bellDot)
    }
}
