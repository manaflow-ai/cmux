import AppKit
@testable import CmuxNextAgentPane
import WebKit
import Testing

/// Leo, 2026-10-21: a blue keyboard / Caps Lock bubble floated over the composer's + button. It is
/// macOS's caret accessory (macOS 14): the system draws it beside the caret of the focused field, and
/// the caret of an empty prompt sits right above the + button. The agent pane's web view (the old host) now answers
/// `preferredTextAccessoryPlacement` (`NSTextInputClient`) with `.invisible`, so the system draws none
/// over the agent pane. Asked through the Objective-C runtime, as AppKit asks.
@MainActor
struct AgentPaneTextAccessoryTests {
    @Test func theAgentPaneWebViewShowsNoCaretAccessory() throws {
        let web = AgentPaneWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        try #require(web.responds(to: NSSelectorFromString("preferredTextAccessoryPlacement")))
        let raw = try #require(web.value(forKey: "preferredTextAccessoryPlacement") as? Int)
        #expect(NSTextCursorAccessoryPlacement(rawValue: raw) == .invisible)
    }
}
