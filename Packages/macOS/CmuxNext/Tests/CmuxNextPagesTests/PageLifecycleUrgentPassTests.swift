import CmuxNextCompat
import CmuxNextHibernation
@testable import CmuxNextPages
import CmuxNextSettings
import Testing

/// ``PageLifecycle``'s side of the app's one urgent pass over tabs, chats and pages: it
/// offers the hidden pages nothing keeps and whose discard frees an engine page
/// (``PageLifecycle/urgentCandidates()``), discards the one the ranker chose at once, with no page call
/// and no lifecycle pass (``PageLifecycle/urgentDiscard(_:)``), and with `memoryUrgentDiscardRanking`
/// (``PageLifecycle/leavesCriticalEventToUrgentPass``) leaves the critical event's discard to that pass:
/// its own passes discard nothing until one urgent pace interval after it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct PageLifecycleUrgentPassTests {
    /// Counts the lifecycle's passes.
    private final class Passes {
        var count = 0
    }

    /// A page that logs each step.
    private final class FakePage {
        let name: String
        var reasons: Set<PageLifecyclePlanner.KeepReason> = []
        var lines: [String] = []
        var holdsEngine = true
        var refusesDiscard = false

        init(_ name: String) {
            self.name = name
        }
    }

    private struct Target: PageLifecycleTarget {
        let page: FakePage
        let group: String
        var object: AnyObject? { page }
        var lifecycleGroup: String? { group }
        var lifecycleKeepReasons: Set<PageLifecyclePlanner.KeepReason> { page.reasons }
        var holdsEnginePage: Bool { page.holdsEngine }
        func reportsReasonChanges(to lifecycle: PageLifecycle) {}
        func keepHideSnapshot() {}
        func dropHideSnapshot() {}
        func freeze() -> Bool {
            page.lines.append("freeze")
            return true
        }
        func thaw() { page.lines.append("thaw") }
        func discard() -> Bool {
            page.lines.append(page.refusesDiscard ? "refuse" : "discard")
            return !page.refusesDiscard
        }
    }

    private let rig = LifecycleDeadlineRig()
    private let lifecycle: PageLifecycle

    init() {
        lifecycle = PageLifecycle(conditions: .discarding(), deadlines: rig.scheduler)
    }

    @Test func theUrgentPassListsHiddenPagesNothingKeepsAndDiscardsTheChosenOneAtOnce() {
        let history = FakePage("history"), chat = FakePage("chat"), draft = FakePage("draft"), shown = FakePage("shown")
        draft.reasons = [.draft]
        let passes = Passes()
        lifecycle.didRunPass = { passes.count += 1 }
        lifecycle.hide("h", page: Target(page: history, group: "privileged"))
        lifecycle.hide("c", page: Target(page: chat, group: "agent"))
        lifecycle.hide("d", page: Target(page: draft, group: "agent"))
        lifecycle.show("s", page: Target(page: shown, group: "viewer"))
        rig.advance(to: .seconds(20))

        let candidates = lifecycle.urgentCandidates()
        #expect(Set(candidates.map(\.key)) == ["h", "c"], "a page with a discard-blocking reason or a shown one was offered")
        #expect(candidates.first { $0.key == "c" }?.kind == .agentPage)
        #expect(candidates.first { $0.key == "h" }?.kind == .internalPage)

        #expect(lifecycle.urgentDiscard("h"))
        #expect(lifecycle.state(of: "h") == .discarded)
        #expect(history.lines == ["discard"], "the urgent discard called into the page or skipped the discard")
        #expect(passes.count == 0, "the urgent discard ran a lifecycle pass")
        #expect(!lifecycle.urgentDiscard("h"), "a discarded page went again")
        #expect(!lifecycle.urgentDiscard("s"), "a shown page was discarded")
        #expect(!lifecycle.urgentDiscard("unknown"))
        #expect(lifecycle.urgentCandidates().map(\.key) == ["c"])
    }

    @Test func aPageHiddenLessThanTheMinimumIsNotOffered() {
        let fresh = FakePage("fresh")
        lifecycle.hide("f", page: Target(page: fresh, group: "viewer"))
        rig.advance(to: .seconds(5))
        #expect(lifecycle.urgentCandidates().isEmpty, "a page the person just left joined the urgent pass")
        #expect(!fresh.lines.contains("discard"))
    }

    /// A page whose discard frees nothing (no document yet) is never the critical event's one discard,
    /// and a page that refuses keeps its state, so the ranker takes the next one.
    @Test func aPageWhoseDiscardFreesNothingOrThatRefusesIsNotTaken() {
        let empty = FakePage("empty"), stubborn = FakePage("stubborn")
        empty.holdsEngine = false
        stubborn.refusesDiscard = true
        lifecycle.hide("e", page: Target(page: empty, group: "viewer"))
        lifecycle.hide("s", page: Target(page: stubborn, group: "viewer"))
        rig.advance(to: .seconds(20))
        #expect(lifecycle.urgentCandidates().map(\.key) == ["s"], "a page holding no engine page was offered")
        #expect(!lifecycle.urgentDiscard("s"), "a refused discard counted as the event's discard")
        #expect(lifecycle.state(of: "s") == .hidden)
    }

    /// The judge's case: a page hid 1 s before the pressure turned critical, so a pass was armed before
    /// the event (its hide's recently visible window). That earlier pass, and the event's own look,
    /// discard nothing until one urgent pace interval after the event and after the urgent pass; they
    /// still freeze. Then the lifecycle discards at the urgent pace.
    @Test func noLifecycleDiscardRunsBeforeOneUrgentIntervalAfterTheCriticalEvent() {
        lifecycle.leavesCriticalEventToUrgentPass = true
        let old = FakePage("old"), recent = FakePage("recent")
        lifecycle.hide("o", page: Target(page: old, group: "viewer"))
        rig.advance(to: .seconds(200))
        lifecycle.runPass()
        // The recent page's hide arms a pass for the role it takes from the old one, before the event.
        lifecycle.hide("r", page: Target(page: recent, group: "viewer"))
        let event = Duration.seconds(201)
        rig.advance(to: event)
        let hold = event + .seconds(PageLifecyclePlanner.Timing().urgentPace.interval)
        #expect(lifecycle.nextPassAt.map { $0 < hold } == true, "no pass was armed before the event")

        lifecycle.setConditions(.discarding(.critical))
        #expect(lifecycle.noDiscardBefore == hold)
        lifecycle.urgentPassDidRun()
        var now = event
        for _ in 0..<8 {
            guard let due = lifecycle.nextPassAt, due < hold else { break }
            now = max(now, due)
            rig.advance(to: now)
            lifecycle.runPass()
            #expect(!old.lines.contains("discard") && !recent.lines.contains("discard"),
                    "a lifecycle pass discarded within the critical event's urgent interval")
        }
        #expect(lifecycle.state(of: "o") != .discarded)
        #expect(lifecycle.nextPassAt == hold, "the held discard has no pass at the interval's end")

        rig.advance(to: hold)
        lifecycle.runPass()
        #expect(lifecycle.state(of: "o") == .discarded, "the lifecycle never discarded after the urgent interval")
        #expect(!recent.lines.contains("discard"), "a page hidden under the minimum was discarded")
    }

    /// Without `memoryUrgentDiscardRanking` the lifecycle keeps its own critical pass.
    @Test func withoutTheRankingCriticalPressureStillDiscardsAtOnce() {
        let old = FakePage("old")
        lifecycle.hide("o", page: Target(page: old, group: "viewer"))
        rig.advance(to: .seconds(200))
        lifecycle.setConditions(.discarding(.critical))
        #expect(lifecycle.noDiscardBefore == nil)
        lifecycle.runPass()
        #expect(lifecycle.state(of: "o") == .discarded)
    }

    /// No `browser.hibernation` written (the default, trunk #25920: a page never reloads unless the person
    /// asks) reaches the planner as ``PageLifecyclePlanner/KeepReason/discardsOff``: a hidden page freezes,
    /// which keeps its state, and is never discarded, at any pressure, and the urgent pass may not take
    /// it. Writing the setting looks again at once and lets it go.
    @Test func theDefaultFreezesAHiddenPageAndNeverDiscardsIt() {
        let unwritten = PageLifecycle(deadlines: rig.scheduler)
        #expect(!unwritten.conditions.setting.discardsAutomatically, "the default conditions discard on their own")
        let old = FakePage("old"), last = FakePage("last")
        unwritten.hide("o", page: Target(page: old, group: "agent"))
        rig.advance(to: .seconds(1))
        unwritten.hide("l", page: Target(page: last, group: "viewer"))
        rig.advance(to: .seconds(12))
        unwritten.runPass()
        #expect(unwritten.state(of: "o") == .frozen, "a hidden page did not freeze by default")
        #expect(unwritten.nextPassAt == nil, "a pass is armed though no page changes with time")
        rig.advance(to: .seconds(3_600))
        for pressure in [MemoryPressureLevel.normal, .warning, .critical] {
            unwritten.setConditions(.init(pressure: pressure))
            unwritten.runPass()
            #expect(unwritten.state(of: "o") == .frozen, "\(pressure): a hidden page was discarded by default")
            #expect(unwritten.state(of: "l") == .hidden, "\(pressure)")
            #expect(unwritten.urgentCandidates().isEmpty, "\(pressure): the urgent pass may take a page by default")
        }
        #expect(old.lines == ["freeze"])
        #expect(last.lines.isEmpty)

        unwritten.setConditions(.discarding())
        #expect(unwritten.nextPassAt == .seconds(3_600), "writing browser.hibernation armed no pass")
        unwritten.runPass()
        #expect(unwritten.state(of: "o") == .discarded)
        #expect(unwritten.state(of: "l") == .discarded)
    }

    /// Pressure that leaves critical ends the hold: the warning pace discards on its own deadlines.
    @Test func leavingCriticalPressureEndsTheHold() {
        lifecycle.leavesCriticalEventToUrgentPass = true
        lifecycle.hide("o", page: Target(page: FakePage("old"), group: "viewer"))
        lifecycle.setConditions(.discarding(.critical))
        #expect(lifecycle.noDiscardBefore != nil)
        lifecycle.setConditions(.discarding(.warning))
        #expect(lifecycle.noDiscardBefore == nil)
    }
}

extension PageLifecyclePlanner.Conditions {
    /// `browser.hibernation` written ("moderate"): hidden pages are discarded on their own. With nothing
    /// written (`.init()`, `BrowserHibernationSetting.fallback`) they only freeze (trunk #25920), so the
    /// tests of the discard itself run under this.
    static func discarding(_ pressure: MemoryPressureLevel = .normal) -> Self {
        .init(setting: BrowserHibernationSetting(mode: .moderate), pressure: pressure)
    }
}
