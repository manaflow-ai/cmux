import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `layout.paneBorderColor` and `layout.paneBorderWidth`.
@Suite struct PaneBorderStyleSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func parsesColorAndWidth() throws {
        let snapshot = try parse(##"{"layout": {"paneBorderColor": "#FF8000", "paneBorderWidth": 2}}"##)
        #expect(snapshot.paneChrome.borderColor == ThemeRGB(hex: 0xFF8000))
        #expect(snapshot.paneChrome.borderWidth == 2)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func colorTakesAnAlphaByte() throws {
        let color = try #require(try parse(##"{"layout": {"paneBorderColor": "#ffffff80"}}"##).paneChrome.borderColor)
        #expect(color.red == 1 && color.green == 1 && color.blue == 1)
        #expect(abs(color.alpha - 128.0 / 255) < 0.001)
    }

    @Test func unsetKeysFollowTheThemeAndAHairline() throws {
        let chrome = try parse("{}").paneChrome
        #expect(chrome.borderColor == nil)
        #expect(chrome.borderWidth == nil)
    }

    @Test func badValuesAreSkippedWithDiagnostics() throws {
        let snapshot = try parse(#"{"layout": {"paneBorderColor": "orange", "paneBorderWidth": 9}}"#)
        #expect(snapshot.paneChrome.borderColor == nil)
        #expect(snapshot.paneChrome.borderWidth == 4)  // clamped
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["layout.paneBorderColor", "layout.paneBorderWidth"])
    }
}
