import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The chat header's Terminal button with Debug Settings `agentChat.terminalButtonAdds` (Leo
/// 2026-10-15: "maybe not a toggle; clicking the terminal button adds another terminal on the right
/// each time"): every click opens a new terminal on the chat's right (RightColumnPlacement: a tab in
/// the pane already holding a terminal, never another column). Off, the button still toggles its terminal.
@MainActor
struct HeaderTerminalAddsTests {
    static let key = "agentChat.terminalButtonAdds"

    /// Runs `body` with the toggle set to `on` for this test only (the store has no file, so
    /// nothing is written).
    func with(adds on: Bool, _ body: () -> Void) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TunableCatalog.all)
        TunableStore.shared.set(Self.key, .bool(on))
        defer { TunableStore.shared.set(Self.key, nil) }
        body()
    }

    @Test func eachClickAddsATerminalOnTheChatsRight() {
        with(adds: true) {
            let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
            for count in 1...3 {
                row.click("splitRight", toggles: toggles)
                #expect(row.order == ["chat"] + Array(repeating: "terminal", count: count))
            }
            // Each asks the right column for a terminal; none is a Split Right of the one before.
            #expect(row.tools.map(\.kind) == [.terminal, .terminal, .terminal])
            #expect(row.invocations["splitRight"] == nil)
        }
    }

    @Test func offTheButtonStillTogglesItsTerminal() {
        with(adds: false) {
            let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "terminal"])
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat"])
        }
    }

    /// A click adds a terminal and never closes one, so the Terminal button never shows lit, while
    /// the other buttons still light for their splits.
    @Test func theTerminalButtonNeverShowsLit() {
        with(adds: true) {
            let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
            row.click("splitRight", toggles: toggles)
            #expect(toggles.headerState(chat: row.chat, store: row.store).lit == [])
            row.click("splitBrowserRight", toggles: toggles)
            row.click("splitRight", toggles: toggles)
            #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["splitBrowserRight"])
        }
    }

    /// Turned off after three adds, the button toggles again: the terminals the adds opened stay and
    /// stay, so the next click opens one more terminal and the click after closes it (not one close per remaining terminal).
    @Test func turnedOffMidSessionTheButtonTogglesAgain() {
        let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
        with(adds: true) {
            for _ in 0..<3 { row.click("splitRight", toggles: toggles) }
        }
        #expect(row.order == ["chat", "terminal", "terminal", "terminal"])
        let added = Array(row.tabs.dropFirst())
        with(adds: false) {
            row.click("splitRight", toggles: toggles)
            #expect(Array(row.tabs.prefix(4)) == [row.chat] + added)
            #expect(row.order == ["chat", "terminal", "terminal", "terminal", "terminal"])
            #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["splitRight"])
            row.click("splitRight", toggles: toggles)
            #expect(row.tabs == [row.chat] + added)
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "terminal", "terminal", "terminal", "terminal"])
        }
    }

    /// Split Down's terminal stays its own after adds and a toggle off: the button still lights for
    /// it and its click closes it, never a terminal the Terminal button opened.
    @Test func splitDownKeepsItsTerminalAfterAdds() {
        let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
        row.click("splitDown", toggles: toggles)
        let down = row.tabs[1]
        with(adds: true) {
            for _ in 0..<3 { row.click("splitRight", toggles: toggles) }
        }
        let added = row.tabs.filter { $0 != row.chat && $0 != down }
        with(adds: false) {
            row.click("splitRight", toggles: toggles)
            #expect(toggles.headerState(chat: row.chat, store: row.store).lit.contains("splitDown"))
            row.click("splitDown", toggles: toggles)
            #expect(!row.tabs.contains(down))
            #expect(added.allSatisfy(row.tabs.contains))
        }
    }

    /// Many adds keep the other buttons' splits: Browser stays lit and its next click closes its
    /// browser rather than opening a second one.
    @Test func manyAddsKeepTheOtherButtonsSplits() {
        with(adds: true) {
            let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
            row.click("splitBrowserRight", toggles: toggles)
            for _ in 0..<8 { row.click("splitRight", toggles: toggles) }
            #expect(row.order == ["chat", "browser"] + Array(repeating: "terminal", count: 8))
            #expect(toggles.headerState(chat: row.chat, store: row.store).lit == ["splitBrowserRight"])
            row.click("splitBrowserRight", toggles: toggles)
            #expect(row.order == ["chat"] + Array(repeating: "terminal", count: 8))
        }
    }
}
