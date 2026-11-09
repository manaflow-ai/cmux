import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Foundation
import Testing
import CmuxNextDesignTokens

/// `appearance.font` (Leo 2026-11-08: "there's no whole app font change thing"): one family the
/// chrome's labels (`Typography`) and every page's `--font-ui` (`WebTheme.uiFont`) draw in.
@MainActor
struct AppFontTests {
    @Test func chromeTextDrawsInTheAppFontAndBackInTheSystemFont() {
        let before = DesignSettings.shared.appFontFamily
        defer { DesignSettings.shared.appFontFamily = before }
        DesignSettings.shared.appFontFamily = nil
        let system = Typography.body.familyName
        DesignSettings.shared.appFontFamily = "Georgia"
        #expect(Typography.body.familyName == "Georgia")
        #expect(Typography.header.familyName == "Georgia")
        // Code-like designs keep the system's monospaced faces.
        #expect(Typography.shortcut.familyName != "Georgia")
        DesignSettings.shared.appFontFamily = nil
        #expect(Typography.body.familyName == system)
    }

    @Test func aFamilyThatIsNotInstalledDrawsTheSystemFont() {
        let before = DesignSettings.shared.appFontFamily
        defer { DesignSettings.shared.appFontFamily = before }
        DesignSettings.shared.appFontFamily = nil
        let system = Typography.body.familyName
        DesignSettings.shared.appFontFamily = "No Such Family 7f3c"
        #expect(Typography.body.familyName == system)
    }

    @Test func pagesGetTheAppFontAsTheirUIFontStack() throws {
        let before = DesignSettings.shared.appFontFamily
        defer { DesignSettings.shared.appFontFamily = before }
        let tokens = ThemeTokens.derive(from: ThemeInput(background: ThemeRGB(hex: 0x101018), foreground: ThemeRGB(hex: 0xE8E8F0), palette: Array(repeating: ThemeRGB(hex: 0x808080), count: 16)))
        DesignSettings.shared.appFontFamily = nil
        let plain = try #require(JSONSerialization.jsonObject(with: Data(WebTheme(tokens).payloadJSON.utf8)) as? [String: Any])
        #expect(plain["uiFont"] == nil)
        DesignSettings.shared.appFontFamily = "Avenir Next"
        let theme = WebTheme(tokens)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(theme.payloadJSON.utf8)) as? [String: Any])
        #expect(payload["uiFont"] as? String == "\"Avenir Next\", -apple-system, BlinkMacSystemFont, system-ui, sans-serif")
        #expect(WebTheme.bootstrapScript.contains("html:root{--font-ui:"))
        #expect(WebTheme.bootstrapScript.contains("applyUiFont(typeof payload.uiFont === 'string' ? payload.uiFont : null)"))
    }

    @Test func aFamilyNameCannotEndTheRuleItGoesIn() {
        #expect(WebTheme.uiFontStack("Evil\"}body{color:red;") == "\"Evilbodycolor:red\", -apple-system, BlinkMacSystemFont, system-ui, sans-serif")
        #expect(WebTheme.uiFontStack(nil) == nil)
        #expect(WebTheme.uiFontStack(" \"; ") == nil)
    }
}
