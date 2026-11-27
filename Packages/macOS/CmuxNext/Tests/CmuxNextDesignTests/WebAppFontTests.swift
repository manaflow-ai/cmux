import AppKit
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxTheme
import Foundation
import Testing
import WebKit

/// `appearance.appFont` reaches every cmux web page through the one web theme (``WebTheme``): its
/// stack becomes the page's `--font-ui` live, under the page's inline styles (a chat Interface Font
/// the person picked keeps winning in the chat), and unset gives the page its own system stack back.
@MainActor @Suite(.serialized) struct WebAppFontTests {
    @MainActor final class Loader: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume()
            done = nil
        }
    }

    private static let html = """
    <html><head><style>:root{--font-ui:-apple-system, BlinkMacSystemFont, system-ui, sans-serif}</style></head><body><p id="text">text</p></body></html>
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

    private func fontUI(_ web: WKWebView) async throws -> String {
        let value = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--font-ui').trim()")
        return value as? String ?? ""
    }

    private func apply(_ web: WKWebView, _ stack: String) async throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: [stack], options: [.fragmentsAllowed]), encoding: .utf8) ?? "[\"\"]"
        _ = try await web.evaluateJavaScript("window.cmuxTheme.apply({variables:{},colorScheme:'light',appFont:\(json)[0]})")
    }

    @Test func theAppFontDrivesThePageFontLiveAndUnsetRestoresIt() async throws {
        let (web, loader) = try await page()
        let system = try await fontUI(web)
        try await apply(web, WebTheme.appFontStack("Avenir Next"))
        #expect(try await fontUI(web).hasPrefix("\"Avenir Next\""))
        try await apply(web, WebTheme.appFontStack("Georgia"))
        #expect(try await fontUI(web).hasPrefix("\"Georgia\""))
        _ = try await web.evaluateJavaScript("document.documentElement.style.setProperty('--font-ui', 'Chat Pick')")
        #expect(try await fontUI(web) == "Chat Pick", "an inline page font (the chat's own pick) still wins")
        _ = try await web.evaluateJavaScript("document.documentElement.style.removeProperty('--font-ui')")
        try await apply(web, "")
        #expect(try await fontUI(web) == system, "unset gives the page its own stack back")
        withExtendedLifetime(loader) {}
    }

    @Test func theStackIsTheFamilyThenTheSystemFont() {
        #expect(WebTheme.appFontStack(nil) == "")
        #expect(WebTheme.appFontStack("  ") == "")
        #expect(WebTheme.appFontStack(" Avenir Next ") == "\"Avenir Next\", -apple-system, BlinkMacSystemFont, system-ui, sans-serif")
        #expect(WebTheme.appFontStack("Bad\"Name") == "")
    }

    @Test func theThemePayloadCarriesTheAppFont() throws {
        let design = DesignSettings.shared
        let before = design.appFont
        defer { design.appFont = before }
        design.appFont = "Avenir Next"
        let theme = WebTheme(ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0))))
        let payload = try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
        #expect((payload["appFont"] as? String)?.hasPrefix("\"Avenir Next\"") == true)
        #expect(WebTheme.pushInputs.contains("Avenir Next"), "a change repaints every page")
    }
}
