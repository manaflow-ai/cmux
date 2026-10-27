@testable import CmuxNextBrowserAutomation
import Foundation
import Testing

/// cmux https://github.com/manaflow-ai/cmux/issues/25830: a browser session never opens a
/// `javascript:` or `vbscript:` URL, which would run code in the current page outside the Secure
/// Store login guard. Every other URL opens as before.
@Suite struct WebKitDriverNavigationTests {
    @Test func pagesOpenAsBefore() throws {
        #expect(try WebKitDriver.agentNavigableURL("https://example.com/a", method: "tab.navigate").absoluteString == "https://example.com/a")
        #expect(try WebKitDriver.agentNavigableURL("about:blank", method: "tabs.open").absoluteString == "about:blank")
        #expect(try WebKitDriver.agentNavigableURL("file:///tmp/report.html", method: "tab.navigate").scheme == "file")
        // A bare host (or host and port) gets https, as before.
        #expect(try WebKitDriver.agentNavigableURL("example.com/x", method: "tab.navigate").absoluteString == "https://example.com/x")
    }

    @Test func scriptURLsAreRefused() {
        for raw in ["javascript:alert(document.cookie)", "JavaScript:void(0)", " javascript:x", "vbscript:x"] {
            #expect(throws: DriverError.self, "\(raw)") { _ = try WebKitDriver.agentNavigableURL(raw, method: "tab.navigate") }
        }
    }
}
