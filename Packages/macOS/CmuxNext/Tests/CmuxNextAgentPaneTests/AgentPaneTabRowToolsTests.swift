import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextAgentPane

@MainActor struct AgentPaneTabRowToolsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    /// A page that loads again starts without the old page's native tools: no stale button stays,
    /// and none sends an old id to the new page.
    @Test func aPageThatLoadsAgainDropsItsNativeTools() async {
        let model = AgentPaneModel(host: NoHost())
        model.setTabRowTools([PaneTabRowTool(id: "review", symbol: "checkmark", label: "Review")])
        #expect(model.tabRowTools.map(\.id) == ["review"])
        _ = await model.respond(to: .ready)
        #expect(model.tabRowTools.isEmpty, "the old page's native tools survived its reload")
    }
    @Test func decodesToolsAndNestedMenus() {
        let raw: [String: Any] = [
            "id": "review", "symbol": "checkmark", "label": "Review", "enabled": true, "toggled": false,
            "badge": "2", "menu": [["id": "open", "label": "Open", "enabled": true, "checked": true]],
        ]
        let tools = AgentPaneTabRowTools.list([raw])
        #expect(tools?.first?.id == "review")
        #expect(tools?.first?.menu.first?.checked == true)
    }

    @Test func decodesAbsentOptionalBadgeAndRole() throws {
        let raw: [String: Any] = [
            "id": "review", "symbol": "checkmark", "label": "Review", "enabled": true, "toggled": false,
            "menu": [["id": "open", "label": "Open", "enabled": true]],
        ]
        let tools = try #require(AgentPaneTabRowTools.list([raw]))
        let tool = try #require(tools.first)
        let item = try #require(tool.menu.first)
        #expect(tool.badge == nil)
        #expect(item.role == nil)
    }

    @Test(arguments: ["id", "symbol", "label", "badge"])
    func boundsUtf8ForEveryToolTextField(field: String) throws {
        var raw: [String: Any] = ["id": "x", "symbol": "x", "label": "x", "enabled": true, "toggled": false]
        // Two graphemes, exactly 256 bytes: the encoded-size boundary is independent of String.count.
        let boundary = "a" + String(repeating: "\u{301}", count: 127) + "b"
        raw[field] = boundary
        #expect(try #require(AgentPaneTabRowTools.list([raw])).count == 1)
        raw[field] = boundary + "\u{301}"
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
    }

    @Test(arguments: ["id", "label"])
    func boundsUtf8ForNestedMenuTextFields(field: String) throws {
        let boundary = "a" + String(repeating: "\u{301}", count: 127) + "b"
        var item: [String: Any] = ["id": "child", "label": "Child", "enabled": true]
        var raw: [String: Any] = ["id": "x", "symbol": "x", "label": "x", "enabled": true, "toggled": false]
        item[field] = boundary
        raw["menu"] = [["id": "parent", "label": "Parent", "enabled": true, "children": [item]]]
        let tools = try #require(AgentPaneTabRowTools.list([raw]))
        #expect(tools.first?.menu.first?.children.count == 1)
        item[field] = boundary + "\u{301}"
        raw["menu"] = [["id": "parent", "label": "Parent", "enabled": true, "children": [item]]]
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
    }

    @Test func rejectsPresentInvalidRole() {
        let raw: [String: Any] = [
            "id": "review", "symbol": "checkmark", "label": "Review", "enabled": true, "toggled": false,
            "menu": [["id": "open", "label": "Open", "enabled": true, "role": "invalid"]],
        ]
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
    }

    @Test func decodesVisibleTextWithinItsBounds() throws {
        var raw: [String: Any] = [
            "id": "review", "symbol": "checkmark", "label": "Review", "enabled": true, "toggled": false,
            "text": "#123 ✓3/5",
        ]
        let tool = try #require(AgentPaneTabRowTools.list([raw])?.first)
        #expect(tool.text == "#123 ✓3/5")

        raw["text"] = ""
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
        raw["text"] = "line\nbreak"
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
        raw["text"] = String(repeating: "x", count: 33)
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
        raw["text"] = String(repeating: "a\u{301}", count: 32)
        #expect(try #require(AgentPaneTabRowTools.list([raw])).first?.text == raw["text"] as? String)
        raw["text"] = String(repeating: "a\u{301}\u{302}\u{303}", count: 32)
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
    }

    @Test func decodesOnlyHTTPURLsWithinByteLimit() throws {
        var item: [String: Any] = ["id": "open", "label": "Open", "enabled": true]
        var raw: [String: Any] = [
            "id": "review", "symbol": "checkmark", "label": "Review", "enabled": true, "toggled": false,
            "menu": [item],
        ]
        item["url"] = "https://example.com/pull/123"
        raw["menu"] = [item]
        let decoded = try #require(AgentPaneTabRowTools.list([raw]))
        #expect(decoded.first?.menu.first?.url == "https://example.com/pull/123")

        for value in ["http://example.com", "javascript:alert(1)", "file:///tmp/a", "garbage"] {
            item["url"] = value
            raw["menu"] = [item]
            if value.hasPrefix("http") {
                #expect(AgentPaneTabRowTools.list([raw])?.first?.menu.first?.url == value)
            } else {
                #expect(AgentPaneTabRowTools.list([raw]) == nil)
            }
        }
        item["url"] = "https://example.com/" + String(repeating: "x", count: 2040)
        raw["menu"] = [item]
        #expect(AgentPaneTabRowTools.list([raw]) == nil)
        item["url"] = "https://example.com/" + String(repeating: "x", count: 2020)
        raw["menu"] = [item]
        #expect(try #require(AgentPaneTabRowTools.list([raw])).first?.menu.first?.url == item["url"] as? String)
    }

    @Test func boundsTotalMenuItemsWhilePreservingNormalPayloads() {
        let menu: [[String: Any]] = (0..<17).map { index in
            ["id": "item-\(index)", "label": "Item \(index)", "enabled": true]
        }
        let normal: [Any] = (0..<2).map { index in
            ["id": "tool-\(index)", "symbol": "checkmark", "label": "Tool \(index)",
             "enabled": true, "toggled": false, "menu": menu] as [String: Any]
        }
        let normalTools = AgentPaneTabRowTools.list(normal)
        #expect(normalTools?.count == 2)
        #expect(normalTools?.allSatisfy { $0.menu.count == menu.count } == true)

        let oversized: [Any] = (0..<16).map { index in
            ["id": "tool-\(index)", "symbol": "checkmark", "label": "Tool \(index)",
             "enabled": true, "toggled": false, "menu": menu] as [String: Any]
        }
        #expect(AgentPaneTabRowTools.list(oversized) == nil)
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
