import CoreGraphics
import Testing
@testable import CmuxNextAgentPane

/// Every subagent opened from the transcript stacked one more split below the last
/// (`AgentSubagentPanes`), with no cap and no width floor. Subagents now open where
/// ``RightColumnPlacement`` puts anything opened on the right of the chat (leo-workspace
/// design/pane-placement.md). Leo 2026-10-28: "But I don't know if you want to do more splits versus
/// just adding more to the top tab or space pane, the top pane. I mean the right top pane, and then
/// you split to the bottom once so that you get the three items. But you want four items." Leo
/// 2026-10-30: "subagent stuff... if there's already a thing on the right, there should be logic for
/// just putting it on the lower pane of the right. that kinda split."
@Suite
@MainActor
struct AgentSubagentPanesPlacementTests {
    private func hooks(_ window: RightColumnWindow, focused: @escaping (String) -> Void = { _ in }) -> AgentSubagentPanes.Hooks {
        AgentSubagentPanes.Hooks(
            isOpen: { window.paneOf[$0] != nil },
            focus: { key, _ in focused(key) },
            place: { chat, decision, created, finished in
                #expect(chat == "chat")
                let key = "tab\(window.events.count + 1)"
                window.place(decision, key: key)
                created(key)
                finished(true)
                return true
            },
            column: { _ in window.measured },
            again: { _ in }
        )
    }

    @Test func aFourthSubagentIsATabNotAnotherSplit() {
        let panes = AgentSubagentPanes(), window = RightColumnWindow()
        for agent in ["one", "two", "three", "four"] {
            #expect(panes.open(agent, focus: false, chat: "chat", hooks: hooks(window)))
        }
        #expect(window.events == ["split right", "split below right1", "tab in right2", "tab in right2"],
                "one split right of the chat, one below it, then tabs in the lower pane: never a third split")
        #expect(window.live.count == 2)
    }

    @Test func withSomethingAlreadyOnTheRightTheFirstSubagentSplitsBelowIt() {
        let panes = AgentSubagentPanes(), window = RightColumnWindow()
        window.occupy("diff")
        #expect(panes.open("one", focus: false, chat: "chat", hooks: hooks(window)))
        #expect(window.events == ["split below right1"])
        #expect(window.paneOf["diff"] == "right1", "what was on the right stays")
        #expect(panes.open("two", focus: false, chat: "chat", hooks: hooks(window)))
        #expect(window.events.last == "tab in right2")
    }

    @Test func closingTheLowerSubagentPaneCollapsesItAndTheNextSplitsAgain() {
        let panes = AgentSubagentPanes(), window = RightColumnWindow()
        window.occupy("diff")
        _ = panes.open("one", focus: false, chat: "chat", hooks: hooks(window))
        window.close("tab1")
        #expect(window.live == ["right1"])
        _ = panes.open("two", focus: false, chat: "chat", hooks: hooks(window))
        #expect(window.events == ["split below right1", "split below right1"])
    }

    @Test func anOpenSubagentIsShownNotOpenedAgain() {
        let panes = AgentSubagentPanes(), window = RightColumnWindow()
        var focused: [String] = []
        let hooks = hooks(window) { focused.append($0) }
        #expect(panes.open("one", focus: false, chat: "chat", hooks: hooks))
        #expect(panes.open("one", focus: true, chat: "chat", hooks: hooks))
        #expect(window.events.count == 1)
        #expect(focused == ["tab1"])
    }

    @Test func aNarrowChatOpensItsFirstSubagentAsATabInItsOwnPane() {
        let panes = AgentSubagentPanes(), window = RightColumnWindow()
        // 900 pt halves to 450: under the chat's 480 pt floor.
        window.chatWidth = 900
        #expect(panes.open("one", focus: false, chat: "chat", hooks: hooks(window)))
        #expect(window.events == ["tab in chat"])
    }

    @Test func aNarrowRightColumnTakesTheSecondSubagentAsATab() {
        let panes = AgentSubagentPanes(), window = RightColumnWindow()
        #expect(panes.open("one", focus: false, chat: "chat", hooks: hooks(window)))
        window.rightWidth = 419
        #expect(panes.open("two", focus: false, chat: "chat", hooks: hooks(window)))
        #expect(window.events == ["split right", "tab in right1"])
    }
}
