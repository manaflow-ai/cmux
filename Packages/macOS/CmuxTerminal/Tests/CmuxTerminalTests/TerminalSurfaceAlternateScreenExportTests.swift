import Foundation
import Testing
@testable import CmuxTerminal

/// `isAlternateScreenActive()` reads `active_screen` from the render-grid
/// export by scanning bytes instead of decoding the whole grid, because the
/// text-editing gesture gate and the `terminalAlternateScreen` shortcut key
/// read it on key presses.
struct TerminalSurfaceAlternateScreenExportTests {
    private func export(activeScreen: String, rowText: String = "$ ls") -> Data {
        let escapedText = String(data: try! JSONEncoder().encode(rowText), encoding: .utf8)!
        let json = #"{"row_spans":[{"row":0,"column":0,"style_id":0,"cell_width":1,"text":"#
            + escapedText
            + #"}],"active_screen":""# + activeScreen + #"","anchor":"viewport","history_rows":0}"#
        return Data(json.utf8)
    }

    @Test func readsTheAlternateScreen() {
        #expect(TerminalSurface.renderGridExportActiveScreenIsAlternate(export(activeScreen: "alternate")) == true)
    }

    @Test func readsThePrimaryScreen() {
        #expect(TerminalSurface.renderGridExportActiveScreenIsAlternate(export(activeScreen: "primary")) == false)
    }

    /// Row text is JSON-escaped, so text that spells the key cannot be
    /// mistaken for it.
    @Test func ignoresRowTextThatSpellsTheKey() {
        let data = export(activeScreen: "primary", rowText: #""active_screen":"alternate""#)
        #expect(TerminalSurface.renderGridExportActiveScreenIsAlternate(data) == false)
    }

    /// An export written with whitespace still decodes through the fallback.
    @Test func fallsBackToDecodingAnotherLayout() {
        let spaced = Data(#"{ "row_spans": [], "active_screen": "alternate" }"#.utf8)
        #expect(TerminalSurface.renderGridExportActiveScreenIsAlternate(spaced) == true)
    }

    /// A caller that fails closed can tell an unreadable export from the
    /// primary screen.
    @Test func reportsAnUnreadableExportAsUnknown() {
        #expect(TerminalSurface.renderGridExportActiveScreenIsAlternate(Data("not json".utf8)) == nil)
    }
}
