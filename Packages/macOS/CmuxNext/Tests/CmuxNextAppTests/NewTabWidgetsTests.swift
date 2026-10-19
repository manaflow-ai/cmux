@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// The New Tab widget view (Debug Settings `newTab.widgets`, Leo 2026-10-18): the page context
/// carries `widgets: true` only while the toggle is on, and the toggle ships off.
struct NewTabWidgetsTests {
    @Test func thePageContextCarriesWidgetsOnlyWhenTheToggleIsOn() throws {
        let on = try json(AgentPaneNewTab(kind: .agent).showingWidgets(true))
        #expect(on["widgets"] as? Bool == true)
        let off = try json(AgentPaneNewTab(kind: .agent).showingWidgets(false))
        #expect(off["widgets"] == nil)
    }

    @Test func theToggleShipsOff() {
        #expect(NewTabTunables.widgets.descriptor.key == "newTab.widgets")
        #expect(NewTabTunables.all.contains { $0.key == "newTab.widgets" })
        #expect(NewTabTunables.widgets.defaultValue == false)
    }

    private func json(_ page: AgentPaneNewTab) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    }
}
