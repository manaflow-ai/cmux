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

    /// Go to Next Agent Needing Input (HQ #5329): only a chat at a question or permission prompt is
    /// a destination, never an unseen result or a failure; it cycles them in the Priority view's
    /// needs-you order (pinned, then newest), skips snoozed and archived ones, and starts over at
    /// the first when the one it opened last no longer waits.
    @Test func nextNeedsInputCyclesAndSkipsResultsAndSnoozedChats() {
        func ids(_ marks: AgentPriorityMarks.State = .init(), _ lanes: [AgentActivityLane] = Self.lanes) -> [String] {
            AgentPriorityRanking.needingInput(lanes, marks: marks, now: Self.now).map(\.id)
        }
        #expect(ids() == ["asks-new", "asks"])
        #expect(AgentPriorityRanking.next(after: nil, in: ids()) == "asks-new")
        #expect(AgentPriorityRanking.next(after: "asks-new", in: ids()) == "asks")
        #expect(AgentPriorityRanking.next(after: "asks", in: ids()) == "asks-new")
        #expect(AgentPriorityRanking.next(after: "done", in: ids()) == "asks-new")
        #expect(AgentPriorityRanking.next(after: nil, in: []) == nil)

        let marks = AgentPriorityMarks(defaults: nil)
        marks.togglePin("asks")
        #expect(ids(marks.state) == ["asks", "asks-new"])
        marks.togglePin("asks")
        marks.snooze(Self.lane("asks-new", .input, ago: 1), now: Self.now)
        #expect(ids(marks.state) == ["asks"])
        #expect(AgentPriorityRanking.next(after: "asks-new", in: ids(marks.state)) == "asks")
        marks.archive("asks")
        #expect(ids(marks.state).isEmpty)
        // A fresh request breaks the old snooze stamp; a new ask is never lost.
        #expect(ids(marks.state, [Self.lane("asks-new", .input, ago: 0)]) == ["asks-new"])
    }

    /// The waiting index the action reads instead of ranking every lane: kept on every write, the
    /// watch's per-session one and a whole page alike.
    @Test func theLaneStoreKeepsItsWaitingSessions() {
        let store = AgentLaneStore()
        store.lanes = Dictionary(uniqueKeysWithValues: Self.lanes.map { ($0.id, $0) })
        #expect(store.waiting == ["asks", "asks-new"])
        store.set("working", Self.lane("working", .input, ago: 0))
        #expect(store.waiting == ["asks", "asks-new", "working"])
        store.set("asks", Self.lane("asks", .working, ago: 0))
        store.set("asks-new", nil)
        #expect(store.waiting == ["working"])
        #expect(store.lanes["asks-new"] == nil)
        #expect(store.lanes["asks"]?.state == .working)
        store.lanes = [:]
        #expect(store.waiting.isEmpty)
    }

    /// The chats' reader: every store's waiting chats, a session an earlier store lists being that
    /// store's (a Chief-home copy of a chat that waits here is not a second stop).
    @Test func theChatsListTheirWaitingOnes() {
        let here = AgentLaneStore(), chief = AgentLaneStore()
        here.lanes = Dictionary(uniqueKeysWithValues: Self.lanes.map { ($0.id, $0) })
        chief.lanes = ["asks": Self.lane("asks", .input, ago: 0), "sub": Self.lane("sub", .input, ago: 3), "idle-new": Self.lane("idle-new", .input, ago: 0)]
        let chats = AgentPriorityChats(marks: AgentPriorityMarks(defaults: nil), stores: [here, chief], checksFailing: { _ in false },
                                       archive: { _, _ in })
        #expect(chats.needingInput(now: Self.now).map(\.id) == ["asks-new", "sub", "asks"])
    }

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

    /// Leo 2026-10-21: "the click and drag doesn't quite work for moving guys up... some sort of basic
    /// baked-in priority view thing sends your chat down since you're idle whereas upper ones are
    /// unread". A chat the person drags keeps the place they dropped it in until they drag it again;
    /// the other chats keep ranking around it.
    @Test func aDraggedChatKeepsItsPlaceWhileTheOthersRank() {
        let marks = AgentPriorityMarks(defaults: nil)
        let ranking = AgentPriorityRanking()
        // Ranked: asks-new, asks, done, broke, working, idle-new, idle-old. The person drags idle-new to the top.
        var order = ranking.entries(Self.lanes, marks: marks.state, now: Self.now).map(\.id)
        order.removeAll { $0 == "idle-new" }
        order.insert("idle-new", at: 0)
        marks.place("idle-new", in: order)
        #expect(ranking.entries(Self.lanes, marks: marks.state, now: Self.now).map(\.id) == order)

        // The working chat asks a question: it climbs over the others, never over the dragged chat.
        let lanes = Self.lanes.map { $0.id == "working" ? Self.lane("working", .input, ago: 0) : $0 }
        let shown = ranking.entries(lanes, marks: marks.state, now: Self.now).map(\.id)
        #expect(shown == ["idle-new", "working", "asks-new", "asks", "done", "broke", "idle-old"])

        // A second drag: broke goes under it, and idle-new keeps the place it shows at.
        var next = shown.filter { $0 != "broke" }
        next.insert("broke", at: 1)
        marks.place("broke", in: next)
        #expect(ranking.entries(lanes, marks: marks.state, now: Self.now).map(\.id) == next)

        // A placed idle chat stays past the idle horizon, like a pinned one; the others still age out.
        let later = ranking.entries(lanes, marks: marks.state, now: Self.now.addingTimeInterval(48 * 3600)).map(\.id)
        #expect(later.first == "idle-new" && !later.contains("idle-old"))
        #expect(ranking.nextChange(lanes.filter { $0.id == "idle-new" }, marks: marks.state, now: Self.now) == nil)

        // The places go with the chat when acpmux stops listing it.
        marks.prune(keeping: ["broke"])
        #expect(marks.state.placed == ["broke": 1])
    }

    /// Marks saved before the dragged places existed still load.
    @Test func marksSavedBeforePlacesLoad() throws {
        let saved = Data(#"{"pinned":["a"],"read":{},"snoozed":{},"archived":[],"collapsed":true}"#.utf8)
        let state = try JSONDecoder().decode(AgentPriorityMarks.State.self, from: saved)
        #expect(state.pinned == ["a"] && state.collapsed && state.placed.isEmpty)
    }

    @Test func theBellDotShowsOnlyWhileTheRowsAreOutOfSight() {
        let entries = AgentPriorityRanking().entries(Self.lanes, marks: .init(), now: Self.now)
        #expect(!SidebarPriorityPanel(entries: entries, shown: true).bellDot)
        #expect(SidebarPriorityPanel(entries: entries, shown: true, collapsed: true).bellDot)
        #expect(SidebarPriorityPanel(entries: entries, shown: false).bellDot)
        #expect(!SidebarPriorityPanel(entries: entries.filter { !$0.needsAttention }, shown: false).bellDot)
    }
}
