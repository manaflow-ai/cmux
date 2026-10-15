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
}
