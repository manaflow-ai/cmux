@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-11-04: "never ... acceptable ... linear time growth degradation". The hidden chat planner replanned every
/// hidden page (filters of every page and a sort) on every turn change of any acpmux session, though only a hidden
/// page's own turn can change its plan: with many agents at work elsewhere each of their steps cost O(hidden pages).
@MainActor @Suite(.serialized, .closesItsWindows)
struct HiddenChatTurnCostTests {
    /// Replans run, counted by the planner's clock reads (each replan over a hidden page reads it).
    @MainActor final class Clock { var reads = 0 }

    private static func pump() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func turnsOfChatsThatAreNotHiddenReplanNothingAndAHiddenChatsTurnEndStillDoes() async throws {
        let rig = AgentPageHibernationTests.Rig()
        defer { rig.window.closeAfterTest() }
        let clock = Clock()
        let base = rig.start
        rig.hibernation.now = { [unowned rig] in clock.reads += 1; return base + rig.elapsed }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .normal)
        _ = try rig.hiddenChat("tab_hidden", session: "s-hidden")
        rig.turns.setState(.working, session: "s-hidden")
        await Self.pump()
        rig.elapsed += .seconds(31 * 60) // due, but its turn runs
        let before = clock.reads

        // 200 steps of agents in chats that are not hidden pages.
        for step in 0..<200 {
            rig.turns.setState(step.isMultiple(of: 2) ? .working : .done, session: "s-other-\(step % 7)")
            await Task.yield()
        }
        await Self.pump()
        let woken = clock.reads - before
        print("hidden-chat-turn-cost replans-by-clock-reads for 200 other-chat turn changes: \(woken)")
        #expect(woken == 0, "200 turn changes of other chats woke the hidden chat planner \(woken) times")

        // The hidden chat's own turn ends: it is let go, with no other call.
        rig.turns.setState(.done, session: "s-hidden")
        await rig.settle { rig.tabs.existingView("tab_hidden") == nil }
        #expect(rig.tabs.existingView("tab_hidden") == nil, "the hidden chat's turn end did not release it")
    }

    /// Review of #39291: a page hidden while its turn runs re-arms the observer; a turn that ends before the
    /// observer's first value still replans (the arm's own read is the baseline, not the stream's first value).
    @Test func aTurnThatEndsRightAfterItsChatHidesStillLetsItGo() async throws {
        let rig = AgentPageHibernationTests.Rig()
        defer { rig.window.closeAfterTest() }
        rig.hibernation.update(setting: BrowserHibernationSetting(mode: .moderate), pressure: .critical)
        rig.turns.setState(.working, session: "s-quick")
        _ = try rig.hiddenChat("tab_quick", session: "s-quick")
        rig.elapsed += .seconds(AgentPageHibernation.minimumHidden + 1)
        rig.hibernation.replan() // due, kept for its turn: the observer re-arms for this page
        rig.turns.setState(.done, session: "s-quick") // before the observer's task first runs
        await rig.settle { rig.tabs.existingView("tab_quick") == nil }
        #expect(rig.tabs.existingView("tab_quick") == nil, "a turn end right after the re-arm was lost")
    }
}
