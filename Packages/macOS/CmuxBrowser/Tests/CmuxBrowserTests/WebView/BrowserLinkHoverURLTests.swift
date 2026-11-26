import Foundation
import Testing
@testable import CmuxBrowser

/// Coverage for the link destination a browser pane shows on hover
/// (https://github.com/manaflow-ai/cmux/issues/17149).
struct BrowserLinkHoverURLTests {
    @Test("A hovered link shows its absolute URL")
    func hoveredLinkShowsAbsoluteURL() {
        let result = HitTestResult(absoluteLinkURL: URL(string: "https://example.com/docs?page=2#intro"))
        #expect(BrowserLinkHoverURL(hitTestResult: result)?.displayString == "https://example.com/docs?page=2#intro")
    }

    @Test("Moving off a link shows nothing")
    func elementWithoutLinkShowsNothing() {
        #expect(BrowserLinkHoverURL(hitTestResult: HitTestResult(absoluteLinkURL: nil)) == nil)
        #expect(BrowserLinkHoverURL(url: nil) == nil)
    }

    @Test("A hit-test result without a link property shows nothing")
    func unrelatedObjectShowsNothing() {
        #expect(BrowserLinkHoverURL(hitTestResult: NSObject()) == nil)
    }

    @Test("Hover URLs show unless browser.showLinkHoverURL is off")
    func settingDefaultsToOn() throws {
        let suiteName = "BrowserLinkHoverURLTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(BrowserLinkHoverURL.isEnabled(defaults: defaults))

        defaults.set(false, forKey: "browserShowLinkHoverURL")
        #expect(!BrowserLinkHoverURL.isEnabled(defaults: defaults))
    }

    @Test("A very long link is capped before it reaches the indicator")
    func longLinkIsCapped() throws {
        let payload = String(repeating: "A", count: BrowserLinkHoverURL.maximumDisplayLength * 2)
        let url = try #require(URL(string: "data:text/plain;base64,\(payload)"))
        let hover = try #require(BrowserLinkHoverURL(url: url))
        #expect(hover.displayString.count == BrowserLinkHoverURL.maximumDisplayLength)
        #expect(hover.displayString.hasPrefix("data:text/plain;base64,"))
    }
}

/// Stands in for WebKit's private `_WKHitTestResult`, which exposes the link
/// under the pointer as `absoluteLinkURL`.
private final class HitTestResult: NSObject {
    @objc let absoluteLinkURL: URL?

    init(absoluteLinkURL: URL?) {
        self.absoluteLinkURL = absoluteLinkURL
    }
}
