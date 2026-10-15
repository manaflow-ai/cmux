import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// The chat header's Terminal button with Debug Settings `agentChat.terminalButtonAdds` (Leo
/// 2026-10-15: "maybe not a toggle; clicking the terminal button adds another terminal on the right
/// each time"): every click opens a new terminal right of the last one, through the same Split Right
/// a person's split runs (which focuses its new pane). Off, the button still toggles its terminal.
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

    @Test func eachClickAddsATerminalRightOfTheLastOne() {
        with(adds: true) {
            let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
            row.click("splitRight", toggles: toggles)
            let first = row.tabs[1]
            #expect(row.invocations["splitRight"]?.target?.id == row.chat)
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "terminal", "terminal"])
            // The second terminal splits the first one, so it lands right of it.
            #expect(row.invocations["splitRight"]?.target?.id == first)
            let second = row.tabs[2]
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "terminal", "terminal", "terminal"])
            #expect(row.invocations["splitRight"]?.target?.id == second)
            // A person's split (origin user, asking for a terminal): the new pane takes focus.
            #expect(row.invocations["splitRight"]?.origin == .user)
            #expect(row.invocations["splitRight"]?.opensTerminal == true)
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

    /// Turned off after three adds, the button toggles again: one click closes a terminal, the next
    /// opens one (not a close per remaining terminal).
    @Test func turnedOffMidSessionTheButtonTogglesAgain() {
        let row = HeaderSplitOrderTests.Row(), toggles = AgentChatSplitToggles()
        with(adds: true) {
            for _ in 0..<3 { row.click("splitRight", toggles: toggles) }
        }
        #expect(row.order == ["chat", "terminal", "terminal", "terminal"])
        with(adds: false) {
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "terminal", "terminal"])
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "terminal", "terminal", "terminal"])
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "terminal", "terminal"])
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
