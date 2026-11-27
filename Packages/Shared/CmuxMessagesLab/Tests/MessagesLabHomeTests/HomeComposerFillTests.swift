import AppKit
import CmuxHomeRender
import Testing
@testable import MessagesLabHome

/// The Chief field over a see-through window: the palette's `composeFillOverGlass` tints the field's
/// glass (the web composer's surface there), so its placeholder reads on the same fill as the web
/// composer's (fleet capture of be805d96, text-inputs-glass chief-art: 2.7:1 and 2.4:1 on clear
/// glass). An opaque window clears the tint again.
@MainActor @Suite(.serialized) struct HomeComposerFillTests {
    @Test func aFillTintsTheFieldGlass() {
        let chrome = FieldChrome(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        let fill = NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 240 / 255, alpha: 0.62)
        chrome.applyTheme(light: true, symbol: .black, edge: .black, fill: fill)
        #expect(chrome.field.tintColor == fill)
    }

    @Test func noFillClearsTheTint() {
        let chrome = FieldChrome(frame: NSRect(x: 0, y: 0, width: 240, height: 36))
        chrome.applyTheme(light: true, symbol: .black, edge: .black, fill: .white)
        chrome.applyTheme(light: true, symbol: .black, edge: .black)
        #expect(chrome.field.tintColor == nil)
    }

    @Test func theThemeCarriesThePaletteFill() {
        var palette = HomePalette.themed(.init(background: .gray255(255), foreground: .gray255(29),
                                               accent: .rgb255(2, 132, 254), failure: .rgb255(215, 0, 21)))
        palette = palette.onBackground(.gray255(255, alpha: 0), over: .gray255(255), fieldFillOverGlass: .gray255(240, alpha: 0.62))
        let fill = FixtureTheme(active: palette).active.fieldFill
        #expect(fill != nil)
        #expect(abs((fill?.alphaComponent ?? 0) - 0.62) < 0.001)
    }
}
