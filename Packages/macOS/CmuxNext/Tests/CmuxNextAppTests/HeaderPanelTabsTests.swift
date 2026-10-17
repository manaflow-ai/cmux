import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import Testing

/// Debug Settings `agentChat.panelTabs` (Lucas 2026-10-17): with a panel beside the chat, the header's
/// Terminal and Browser open a tab in that panel's pane instead of another split, so the right side
/// grows tabs, not columns; the header state tells the page to keep its tools in "...". Off, both split
/// as before (HeaderSplitOrderTests).
@MainActor
struct HeaderPanelTabsTests {
    static let key = "agentChat.panelTabs"

    /// Runs `body` with the toggle set to `on` for this test only (the store has no file, so
    /// nothing is written).
    func with(panelTabs on: Bool, _ body: () -> Void) {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TunableCatalog.all)
        TunableStore.shared.set(Self.key, .bool(on))
        defer { TunableStore.shared.set(Self.key, nil) }
        body()
    }

    /// The row with a recording New Terminal Tab (`newSurface`), which the row itself does not model.
    func row() -> (HeaderSplitOrderTests.Row, () -> ActionInvocation?) {
        let row = HeaderSplitOrderTests.Row()
        var last: ActionInvocation?
        row.registry.register(Action(id: "newSurface", title: "newSurface", invoke: { last = $0 }, handler: {}))
        return (row, { last })
    }

    @Test func terminalAndBrowserOpenAsTabsInThePanelBesideTheChat() {
        with(panelTabs: true) {
            let (row, newSurface) = row(), toggles = AgentChatSplitToggles()
            // Alone, Browser opens its panel as before: a split right of the chat.
            row.click("splitBrowserRight", toggles: toggles)
            #expect(row.order == ["chat", "browser"])
            let panel = row.tabs[1]
            // Terminal: a terminal tab in the browser's pane, in the chat's folder; no new split.
            row.click("splitRight", toggles: toggles)
            #expect(newSurface()?.target?.id == panel)
            #expect(newSurface()?["cwd"]?.stringValue == row.cwd)
            #expect(row.order == ["chat", "browser"])
            #expect(row.invocations["splitRight"] == nil)
        }
    }

    @Test func aPaneThePersonOpenedTakesTheTabToo() {
        with(panelTabs: true) {
            let (row, _) = row(), toggles = AgentChatSplitToggles()
            row.userOpens(.pty)
            row.click("splitBrowserRight", toggles: toggles)
            #expect(row.invocations["openBrowser"]?.target?.id == row.tabs[1])
            #expect(row.invocations["openBrowser"]?.besideCaller == true)
            #expect(row.invocations["splitBrowserRight"] == nil)
        }
    }

    @Test func offBothSplitAsBefore() {
        with(panelTabs: false) {
            let (row, newSurface) = row(), toggles = AgentChatSplitToggles()
            row.click("splitBrowserRight", toggles: toggles)
            row.click("splitRight", toggles: toggles)
            #expect(row.order == ["chat", "browser", "terminal"])
            #expect(newSurface() == nil)
        }
    }

    @Test func theHeaderStateCarriesTheToggle() {
        with(panelTabs: true) { #expect(AgentPaneHeaderState().panelTabs) }
        with(panelTabs: false) { #expect(!AgentPaneHeaderState().panelTabs) }
        #expect(AgentPaneHeaderState(panelTabs: true).reply["panelTabs"] as? Bool == true)
    }
}
