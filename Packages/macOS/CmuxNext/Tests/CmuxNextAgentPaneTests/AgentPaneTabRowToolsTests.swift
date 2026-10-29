import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AgentPaneTabRowToolsTests {
    @Test func decodesToolsAndNestedMenus() {
        let raw: [String: Any] = [
            "id": "review", "symbol": "checkmark", "label": "Review", "enabled": true, "toggled": false,
            "badge": "2", "menu": [["id": "open", "label": "Open", "enabled": true, "checked": true]],
        ]
        let tools = AgentPaneTabRowTools.list([raw])
        #expect(tools?.first?.id == "review")
        #expect(tools?.first?.menu.first?.checked == true)
    }

    @Test func rejectsOutOfBoundsListsAndText() {
        let tooMany = (0...AgentPaneTabRowTools.maximumTools).map { _ in
            ["id": "x", "symbol": "x", "label": "x", "enabled": true, "toggled": false] as [String: Any]
        }
        #expect(AgentPaneTabRowTools.list(tooMany) == nil)
        let long = ["id": "x", "symbol": "x", "label": String(repeating: "x", count: 65), "enabled": true, "toggled": false] as [String: Any]
        #expect(AgentPaneTabRowTools.list([long]) == nil)
    }

    @Test func advertisesSetOpAndNativeRowToolsEvent() {
        #expect(AgentPageOps.all.contains("cmux.agent.pane.tabRowTools.set"))
        let event = AgentPageEvent.tabRow(height: 10, trailingInset: 4, nativeRowTools: true)
        #expect(event.value["nativeRowTools"]?.boolValue == true)
    }
}
