@testable import CmuxNextAgentPane
import CmuxNextDesign
import Foundation
import Testing

/// The New Tab widget view (Debug Settings `newTab.widgets`, Leo 2026-10-18): the page context
/// carries `widgets: true` only while it is on, and the toggle ships off.
struct NewTabWidgetsTests {
    @Test func thePageContextCarriesWidgetsOnlyWhenOn() throws {
        #expect(try json(AgentPaneNewTab(kind: .agent, widgets: true))["widgets"] as? Bool == true)
        #expect(try json(AgentPaneNewTab(kind: .agent, widgets: false))["widgets"] == nil)
    }

    @Test func theToggleShipsOffInDebugSettings() throws {
        #expect(AgentPaneTunables.newTabWidgets.key == "newTab.widgets")
        #expect(AgentPaneTunables.newTabWidgets.defaultValue == false)
        #expect(AgentPaneTunables.all.contains { $0.key == "newTab.widgets" })
        // Unset follows the toggle: off unless Debug Settings turned it on.
        let page = AgentPaneNewTab(kind: .agent)
        #expect(page.widgets == (AgentPaneTunables.newTabWidgets.value ? true : nil))
    }

    private func json(_ page: AgentPaneNewTab) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    }
}
