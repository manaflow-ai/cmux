import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import Testing

/// The chats page's snippet subtitle (dealbreakers D4): a row found by what was said shows the
/// message's words emphasized where its folder was. Review of #38431, F1: the subtitle was set after
/// the colors were applied, so a fresh cell drew no snippet and a reused one kept the last row's text.
@MainActor
struct PaletteSubtitleHighlightTests {
    private static func row(_ subtitle: String, highlights: [Int] = []) -> PaletteRow {
        var item = PaletteItem(id: "chat:\(subtitle)", title: "Chat", subtitle: subtitle,
                               primary: PaletteCommand(id: "open", title: "Open", effect: .perform {}))
        item.subtitleHighlights = highlights
        return PaletteRow(item: item, highlights: [], score: 0)
    }

    @Test func aFreshAndAReusedCellDrawTheirOwnSnippet() throws {
        let cell = PaletteRowCell(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        cell.configure(Self.row("…fails on zephyrine columns", highlights: Array(9...17)), isSelected: false)
        #expect(cell.subtitle.stringValue == "…fails on zephyrine columns", "a fresh cell draws the snippet")
        let drawn = cell.subtitle.attributedStringValue
        let range = (drawn.string as NSString).range(of: "zephyrine")
        let word = try #require(drawn.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
        let plain = try #require(drawn.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(word != plain, "the matched word is drawn heavier than the rest")
        cell.configure(Self.row("…the deploy failed", highlights: Array(5...10)), isSelected: false)
        #expect(cell.subtitle.stringValue == "…the deploy failed", "a reused cell draws the new row's snippet")
        cell.configure(Self.row("~/work/api"), isSelected: false)
        #expect(cell.subtitle.stringValue == "~/work/api", "a plain subtitle replaces a snippet")
    }
}
