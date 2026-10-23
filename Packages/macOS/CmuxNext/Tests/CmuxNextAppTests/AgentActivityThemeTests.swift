import AppKit
import CmuxNextAgentActivity
import CmuxNextDesign
import CmuxTheme
import Testing
import WebKit

/// The Activity page (cmux://agent-activity) takes the shared page theme (`--cmux-*`, WebTheme)
/// from the scope it draws in, like every other cmux page, and follows that scope's changes.
@MainActor
struct AgentActivityThemeTests {
    @Test func theActivityPageFollowsItsScopesTheme() async throws {
        let source = AgentActivityMockSource()
        let view = AgentActivityHostView(model: AgentActivityModel(source: source), source: source,
                                         lowPowerMode: LowPowerMode(enabled: false))
        let scripts = view.webView.configuration.userContentController.userScripts.map(\.source)
        #expect(scripts.contains(WebTheme.bootstrapScript))

        let scope = ThemeScope(level: .room)
        scope.root(view)
        func paint(_ foreground: UInt32) throws -> String {
            let input = ThemeInput(background: ThemeRGB(hex: 0x101418), foreground: ThemeRGB(hex: foreground))
            scope.setOverride(try #require(ThemeSpec("Activity Room")), input: input, animated: false)
            return try #require(WebTheme(scope.tokens).variables["--cmux-text"])
        }
        let first = try paint(0xE8D8B0)
        view.webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        #expect(await pageText(view.webView, becomes: first) == first)

        let second = try paint(0xB0D8E8)
        #expect(first != second)
        #expect(await pageText(view.webView, becomes: second) == second)
    }

    /// The `--cmux-text` of the theme the page last took (`cmuxTheme.current`, the payload as sent:
    /// the computed value of a registered color property is serialized another way) once it reads
    /// `expected`, else its last value after 10 s.
    private func pageText(_ webView: WKWebView, becomes expected: String) async -> String? {
        var value: String?
        for _ in 0..<200 {
            value = try? await webView.callAsyncJavaScript(
                "return (window.cmuxTheme && window.cmuxTheme.current && window.cmuxTheme.current.variables['--cmux-text']) || ''",
                contentWorld: .page) as? String
            if value == expected { return value }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return value
    }
}
