import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxTheme
import Foundation
import Testing
import WebKit

/// `appearance.fontSmoothing` reaches every cmux web page through the one web theme
/// (``WebTheme``): `antialiased` and `subpixel` win over each page's own `-webkit-font-smoothing`
/// (the chat's stylesheets set `antialiased` on many rules), live, with no reload; `auto` leaves each
/// page's own style, as before the setting.
@MainActor @Suite(.serialized) struct WebFontSmoothingTests {
    @MainActor final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume()
            done = nil
        }
    }

    private static let html = """
    <html><body><p id="styled" style="-webkit-font-smoothing:antialiased">styled</p><p id="plain">plain</p></body></html>
    """

    private func page() async throws -> (WKWebView, Loader) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let loader = Loader()
        web.navigationDelegate = loader
        await withCheckedContinuation { continuation in
            loader.done = continuation
            web.loadHTMLString(Self.html, baseURL: nil)
        }
        _ = try await web.evaluateJavaScript(WebTheme.bootstrapScript)
        return (web, loader)
    }

    private func smoothing(_ web: WKWebView, _ id: String) async throws -> String {
        let value = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('\(id)')).webkitFontSmoothing")
        return value as? String ?? ""
    }

    private func apply(_ web: WKWebView, _ mode: String) async throws {
        _ = try await web.evaluateJavaScript("window.cmuxTheme.apply({variables:{},colorScheme:'light',fontSmoothing:'\(mode)'})")
    }

    @Test func oneSettingDrivesEveryElementLive() async throws {
        let (web, loader) = try await page()
        try await apply(web, "subpixel")
        #expect(try await smoothing(web, "styled") == "subpixel-antialiased", "subpixel wins over the page's antialiased")
        #expect(try await smoothing(web, "plain") == "subpixel-antialiased")
        try await apply(web, "antialiased")
        #expect(try await smoothing(web, "styled") == "antialiased")
        #expect(try await smoothing(web, "plain") == "antialiased", "antialiased reaches text the page left on auto")
        try await apply(web, "auto")
        #expect(try await smoothing(web, "styled") == "antialiased", "auto gives the page its own style back")
        #expect(try await smoothing(web, "plain") == "auto")
        withExtendedLifetime(loader) {}
    }

    @Test func theThemePayloadCarriesTheSetting() throws {
        let theme = WebTheme(ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))))
        let payload = try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
        #expect(payload["fontSmoothing"] as? String == "auto", "the default leaves each page its own style")
    }
}
