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

    /// `tabs.newTabWidgets.*` (NewTabWidgetSettings): the page context names the widgets on, an empty
    /// list for none; nil (a context from before them) is left out.
    @Test func thePageContextCarriesThePageWidgets() throws {
        #expect(try json(AgentPaneNewTab(kind: .agent, pageWidgets: ["greeting", "chats"]))["pageWidgets"] as? [String] == ["greeting", "chats"])
        #expect(try json(AgentPaneNewTab(kind: .agent, pageWidgets: []))["pageWidgets"] as? [String] == [])
        #expect(try json(AgentPaneNewTab(kind: .agent))["pageWidgets"] == nil)
    }

    /// `headlineOff` is in the context only when the greeting is set to false in cmux.json.
    @Test func thePageContextCarriesHeadlineOffOnlyWhenSet() throws {
        var page = AgentPaneNewTab(kind: .agent, pageWidgets: [])
        #expect(try json(page)["headlineOff"] == nil)
        page.headlineOff = true
        #expect(try json(page)["headlineOff"] as? Bool == true)
    }

    private func json(_ page: AgentPaneNewTab) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
    }
}
