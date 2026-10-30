import CoreGraphics
import Testing
@testable import CmuxNextAgentPane

/// Every subagent opened from the transcript stacked one more split below the last
/// (`AgentSubagentPanes`), with no cap and no width floor. The right column now holds at most two
/// subagent panes, the second split below the first once, and every later subagent is a tab in the
/// newest one's pane (leo-workspace design/pane-placement.md). Leo 2026-10-28: "But I don't know if
/// you want to do more splits versus just adding more to the top tab or space pane, the top pane. I
/// mean the right top pane, and then you split to the bottom once so that you get the three items.
/// But you want four items."
@Suite
@MainActor
struct AgentSubagentPanesPlacementTests {
    /// A window of panes: each open lands at once, in the pane its placement makes.
    @MainActor
    final class Window {
        var paneOf: [String: String] = ["chat": "main"]
        var widths: [String: CGFloat] = ["main": 1400]
        var placed: [(anchor: String, placement: AgentSubagentPanes.Placement)] = []
        var focused: [String] = []
        private var panes = 0

        var hooks: AgentSubagentPanes.Hooks {
            AgentSubagentPanes.Hooks(
                isOpen: { [unowned self] in paneOf[$0] != nil },
                focus: { [unowned self] key, _ in focused.append(key) },
                place: { [unowned self] anchor, placement, created, finished in
                    placed.append((anchor, placement))
                    let key = "tab\(placed.count)"
                    switch placement {
                    case .tab: paneOf[key] = paneOf[anchor]
                    case .right, .down:
                        panes += 1
                        let pane = "split\(panes)", from = paneOf[anchor] ?? "main"
                        // An even split: a right split halves the width, a down split keeps it.
                        let half = (widths[from] ?? 0) / (placement == .right ? 2 : 1)
                        if placement == .right { widths[from] = half }
                        widths[pane] = half
                        paneOf[key] = pane
                    }
                    created(key)
                    finished(true)
                    return true
                },
                pane: { [unowned self] in paneOf[$0] },
                width: { [unowned self] in paneOf[$0].flatMap { widths[$0] } },
                again: { _ in }
            )
        }
    }

    @Test func aFourthSubagentIsATabNotAnotherSplit() {
        let panes = AgentSubagentPanes(), window = Window()
        for agent in ["one", "two", "three", "four"] {
            #expect(panes.open(agent, focus: false, chat: "chat", hooks: window.hooks))
        }
        #expect(window.placed.map(\.placement) == [.right, .down, .tab, .tab],
                "one split right of the chat, one below it, then tabs: never a third split")
        #expect(window.placed[1].anchor == "tab1", "the second splits below the first subagent")
        #expect(window.paneOf["tab3"] == window.paneOf["tab2"] && window.paneOf["tab4"] == window.paneOf["tab2"],
                "later subagents are tabs in the lower subagent pane")
        #expect(Set(window.paneOf.values).count == 3, "the chat and two subagent panes")
    }

    @Test func anOpenSubagentIsShownNotOpenedAgain() {
        let panes = AgentSubagentPanes(), window = Window()
        #expect(panes.open("one", focus: false, chat: "chat", hooks: window.hooks))
        #expect(panes.open("one", focus: true, chat: "chat", hooks: window.hooks))
        #expect(window.placed.count == 1)
        #expect(window.focused == ["tab1"])
    }

    @Test func aNarrowChatOpensItsFirstSubagentAsATabInItsOwnPane() {
        let panes = AgentSubagentPanes(), window = Window()
        // 900 pt halves to 450: under the chat's 480 pt floor.
        window.widths["main"] = 900
        #expect(panes.open("one", focus: false, chat: "chat", hooks: window.hooks))
        #expect(window.placed.map(\.placement) == [.tab])
        #expect(window.paneOf["tab1"] == "main")
    }

    @Test func aNarrowRightColumnTakesTheSecondSubagentAsATab() {
        let panes = AgentSubagentPanes(), window = Window()
        window.widths["main"] = 1000
        #expect(panes.open("one", focus: false, chat: "chat", hooks: window.hooks))
        window.widths["split1"] = 419
        #expect(panes.open("two", focus: false, chat: "chat", hooks: window.hooks))
        #expect(window.placed.map(\.placement) == [.right, .tab])
        #expect(window.paneOf["tab2"] == "split1")
    }

    @Test func aClosedLowerPaneIsSplitAgainOnce() {
        let panes = AgentSubagentPanes(), window = Window()
        for agent in ["one", "two"] { _ = panes.open(agent, focus: false, chat: "chat", hooks: window.hooks) }
        window.paneOf["tab2"] = nil
        #expect(panes.open("three", focus: false, chat: "chat", hooks: window.hooks))
        #expect(panes.open("four", focus: false, chat: "chat", hooks: window.hooks))
        #expect(window.placed.map(\.placement) == [.right, .down, .down, .tab])
    }
}
