import Testing
@testable import CmuxNextAgentPane

/// Settings' icon chooser (user 12922): each gesture becomes the one `_acpmux/harness/icon`
/// request acpmux answers; an image of another type or an empty value sends nothing.
@Suite struct AgentHarnessIconChangeTests {
    @Test func eachGestureNamesOneRequest() throws {
        let typed = try #require(AgentHarnessIconChange(["icon": " 🦊 "]))
        #expect(typed == .value("🦊"))
        #expect(typed.params(id: "acme")["icon"] as? String == "🦊")
        let image = try #require(AgentHarnessIconChange(["data": "iVBORw==", "ext": "SVG"]))
        #expect(image == .image(base64: "iVBORw==", ext: "svg"))
        #expect(image.params(id: "acme")["ext"] as? String == "svg")
        let clear = try #require(AgentHarnessIconChange(["clear": true, "icon": "🦊"]))
        #expect(clear.params(id: "acme")["clear"] as? Bool == true)
        #expect(clear.params(id: "acme")["icon"] == nil)
    }

    @Test func nothingToSetSendsNothing() {
        #expect(AgentHarnessIconChange(["icon": "  "]) == nil)
        #expect(AgentHarnessIconChange(["data": "R0lGOD", "ext": "gif"]) == nil)
        #expect(AgentHarnessIconChange([:]) == nil)
    }
}
