import Testing
@testable import CmuxNextAgentPane

/// A one-tab pane's row is no band over its chat (Leo, 2026-11-03: "isn't it kinda arbitrary anyway if
/// you literally only have one tab there?"): the pane tells the page so in the `tabRow` event, and the
/// page runs its transcript up under the row. Two or more tabs keep the row as before.
@MainActor
struct AgentPaneTabRowSoloTests {
    @Test func theTabRowEventCarriesTheSoloFlag() {
        #expect(AgentPageEvent.tabRow(height: 38, trailingInset: 30, nativeRowTools: false, soloTab: true).value["soloTab"]?.boolValue == true)
        #expect(AgentPageEvent.tabRow(height: 38, trailingInset: 30, nativeRowTools: false).value["soloTab"]?.boolValue == false)
    }

    @Test func aRowNeverOfferedSendsNoSoloFlag() {
        let row = AgentPaneTabRow()
        row.tabsShown = false // the pane hid its lone tab (#33132)
        #expect(row.event.value["soloTab"]?.boolValue == false, "a solo flag went out with no row offered")
    }
}
