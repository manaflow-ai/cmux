import AppKit
@testable import CmuxNextDesign
import Testing
import WebKit

/// The shared web theme (`WebTheme`): a page with the bootstrap script
/// paints `--cmux-surface-background` on `html` (the surface token in an
/// opaque window, transparent over a see-through one), keeps `body`
/// transparent, and follows a live theme change.
@MainActor @Suite(.serialized) struct WebThemeTests {
    final class Loaded: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private func page(_ loaded: Loaded) async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 100), configuration: configuration)
        webView.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.continuation = continuation
            webView.loadHTMLString("<html><head></head><body style=\"background:red\">page</body></html>", baseURL: nil)
        }
        return webView
    }

    private func eval(_ webView: WKWebView, _ script: String) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                continuation.resume(returning: result.map { "\($0)" } ?? "error: \(String(describing: error))")
            }
        }
    }

    private func tokens(opacity: Double) -> ThemeTokens {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = opacity
        return ThemeTokens.derive(from: input)
    }

    private static func rgb(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        return "rgb(\(channel(color.red)), \(channel(color.green)), \(channel(color.blue)))"
    }

    @Test func anOpaqueThemePaintsTheTokenOnHtmlAndBodyIsClear() async {
        let loaded = Loaded()
        let webView = await page(loaded)
        let opaque = tokens(opacity: 1)
        _ = await eval(webView, WebTheme(opaque).applyScript)
        let variable = await eval(webView, "getComputedStyle(document.documentElement).getPropertyValue('--cmux-surface-background').trim()")
        #expect(variable == WebTheme.css(opaque.surfaceBackground.withAlpha(1)))
        #expect(await eval(webView, "getComputedStyle(document.documentElement).backgroundColor") == Self.rgb(opaque.surfaceBackground))
        #expect(await eval(webView, "getComputedStyle(document.body).backgroundColor") == "rgba(0, 0, 0, 0)")
        #expect(await eval(webView, "document.documentElement.style.colorScheme") == "dark")
    }

    @Test func aSeeThroughThemeLeavesThePageClearAndFollowsALiveChange() async {
        let loaded = Loaded()
        let webView = await page(loaded)
        _ = await eval(webView, WebTheme(tokens(opacity: 0.6)).applyScript)
        let html = await eval(webView, "getComputedStyle(document.documentElement).backgroundColor")
        #expect(html.hasSuffix(", 0)") || html == "transparent", "the window's one backdrop shows through: \(html)")
        #expect(await eval(webView, "getComputedStyle(document.body).backgroundColor") == "rgba(0, 0, 0, 0)")
        // A live theme change (opacity back to 1) repaints the page.
        let opaque = tokens(opacity: 1)
        _ = await eval(webView, WebTheme(opaque).applyScript)
        #expect(await eval(webView, "getComputedStyle(document.documentElement).backgroundColor") == Self.rgb(opaque.surfaceBackground))
        #expect(await eval(webView, "window.cmuxTheme.current.variables['--cmux-surface-token']") == WebTheme.css(opaque.surfaceBackground))
    }

    @Test func theVariablesAreTheNativeTokens() {
        let opaque = tokens(opacity: 1)
        let theme = WebTheme(opaque)
        #expect(theme.variables["--cmux-surface-token"] == WebTheme.css(opaque.surfaceBackground))
        #expect(theme.variables["--cmux-text"] == WebTheme.css(opaque.textPrimary))
        #expect(WebTheme(tokens(opacity: 0.6)).variables["--cmux-surface-background"]?.hasSuffix(", 0.0)") == true)
    }
}
