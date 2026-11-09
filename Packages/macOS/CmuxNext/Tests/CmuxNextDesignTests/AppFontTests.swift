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

/// Chrome already on screen follows a change of the app font (#39272 review F1): labels took their
/// font when they were made, so the walk gives each one in the old app face the new one, at its own
/// size and weight, and leaves monospaced and tabular-digit text alone.
@MainActor
struct AppFontRetargetTests {
    @Test func mountedLabelsMoveToTheNewFaceAndBack() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        root.wantsLayer = true
        let label = NSTextField(labelWithString: "Tab")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let mono = NSTextField(labelWithString: "⌘K")
        mono.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let digits = NSTextField(labelWithString: "12")
        digits.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let layer = ChromeTextLayer()
        layer.font = .systemFont(ofSize: 12)
        [label, mono, digits].forEach(root.addSubview)
        try #require(root.layer).addSublayer(layer)
        let monoFamily = mono.font?.familyName

        AppFontRetarget.apply(to: root, from: nil, to: "Georgia")
        #expect(label.font?.familyName == "Georgia")
        #expect(label.font?.pointSize == 13)
        #expect(layer.font.familyName == "Georgia")
        #expect(mono.font?.familyName == monoFamily)
        #expect(digits.font?.familyName != "Georgia")

        AppFontRetarget.apply(to: root, from: "Georgia", to: "Avenir Next")
        #expect(label.font?.familyName == "Avenir Next")

        AppFontRetarget.apply(to: root, from: "Avenir Next", to: nil)
        #expect(label.font?.familyName == NSFont.systemFont(ofSize: 13).familyName)
        #expect(layer.font.familyName == NSFont.systemFont(ofSize: 12).familyName)
    }

    @Test func richTextKeepsItsOtherRuns() {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        text.textStorage?.setAttributedString(NSAttributedString(string: "ab", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        text.textStorage?.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: NSRange(location: 1, length: 1))
        AppFontRetarget.apply(to: text, from: nil, to: "Georgia")
        let first = text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let second = text.textStorage?.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        #expect(first?.familyName == "Georgia")
        #expect(second?.familyName != "Georgia")
    }
}
