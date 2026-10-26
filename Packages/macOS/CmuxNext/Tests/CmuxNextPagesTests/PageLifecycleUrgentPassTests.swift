import CmuxNextHibernation
@testable import CmuxNextPages
import Testing

/// ``PageLifecycle``'s side of the app's one urgent pass over tabs, chats and pages (p13-webui-092): it
/// offers the hidden pages nothing keeps (``PageLifecycle/urgentCandidates()``) and discards the one the
/// ranker chose at once, with no page call and no lifecycle pass (``PageLifecycle/discardNow(_:)``).
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
        func reportsReasonChanges(to lifecycle: PageLifecycle) {}
        func keepHideSnapshot() {}
        func dropHideSnapshot() {}
        func freeze() { page.lines.append("freeze") }
        func thaw() { page.lines.append("thaw") }
        func discard() { page.lines.append("discard") }
    }

    private let rig = LifecycleDeadlineRig()
    private let lifecycle: PageLifecycle

    init() {
        lifecycle = PageLifecycle(deadlines: rig.scheduler)
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

        #expect(lifecycle.discardNow("h"))
        #expect(lifecycle.state(of: "h") == .discarded)
        #expect(history.lines == ["discard"], "the urgent discard called into the page or skipped the discard")
        #expect(passes.count == 0, "the urgent discard ran a lifecycle pass")
        #expect(!lifecycle.discardNow("h"), "a discarded page went again")
        #expect(!lifecycle.discardNow("s"), "a shown page was discarded")
        #expect(!lifecycle.discardNow("unknown"))
        #expect(lifecycle.urgentCandidates().map(\.key) == ["c"])
    }

    @Test func aPageHiddenLessThanTheMinimumIsNotOffered() {
        let fresh = FakePage("fresh")
        lifecycle.hide("f", page: Target(page: fresh, group: "viewer"))
        rig.advance(to: .seconds(5))
        #expect(lifecycle.urgentCandidates().isEmpty, "a page the person just left joined the urgent pass")
        #expect(!fresh.lines.contains("discard"))
    }
}
