import AppKit
@testable import CmuxNextApp
import Testing

/// The workspace menu's color row reads as one of the menu's items: its title starts where the
/// other items' titles start, and its swatches end where the shortcuts end. A capture of the
/// shipped menu put the other titles' ink 23 pt from the menu's left edge and the shortcuts'
/// 13 pt from its right edge; this row's title sat 6 pt left of them, and its last swatch 6 pt
/// from the right edge.
@MainActor
struct WorkspaceColorSwatchRowTests {
    private let title = "Set Workspace Color"
    private let width: CGFloat = 360

    /// The inked columns of the row's left half (the title) or right half (the swatches), in
    /// points from the row's left edge.
    private func ink(rightHalf: Bool = false) throws -> ClosedRange<CGFloat> {
        let choices = ["Red", "Blue", "Green"].map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
        let row = WorkspaceColorSwatchView(title: title, choices: choices)
        row.frame.size.width = width
        row.layout()
        let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / row.bounds.width
        let half = rep.pixelsWide / 2
        let columns = (rightHalf ? half..<rep.pixelsWide : 0..<half).filter { x in
            (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 }
        }
        let first = try #require(columns.first), last = try #require(columns.last)
        return CGFloat(first) / scale...CGFloat(last + 1) / scale
    }

    @Test func startsItsTitleWhereTheOtherItemsTitlesStart() throws {
        let leading = try ink().lowerBound
        #expect((22...24).contains(leading), "title ink starts at \(leading) pt")
    }

    @Test func endsItsSwatchesWhereTheShortcutsEnd() throws {
        let trailing = width - (try ink(rightHalf: true)).upperBound
        #expect((12...14).contains(trailing), "last swatch ends \(trailing) pt from the right edge")
    }
}
