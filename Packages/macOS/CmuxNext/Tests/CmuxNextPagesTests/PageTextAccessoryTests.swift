import AppKit
@testable import CmuxNextPages
import Testing

/// Leo, 2026-10-21: a blue keyboard / Caps Lock bubble floated over the composer's + button. It is
/// macOS's caret accessory (macOS 14): the system draws it beside the caret of the focused field, and
/// the caret of an empty prompt sits right above the + button. A cmux page's web view now answers
/// `preferredTextAccessoryPlacement` (`NSTextInputClient`) with `.invisible`, so the system draws none
/// over a cmux page. Asked through the Objective-C runtime, as AppKit asks.
@MainActor
struct PageTextAccessoryTests {
    @Test func aPageWebViewShowsNoCaretAccessory() throws {
        let web = PageWKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: .init())
        try #require(web.responds(to: NSSelectorFromString("preferredTextAccessoryPlacement")))
        let raw = try #require(web.value(forKey: "preferredTextAccessoryPlacement") as? Int)
        #expect(NSTextCursorAccessoryPlacement(rawValue: raw) == .invisible)
    }
}
