import AppKit
@testable import CmuxNextApp
import Testing

/// The workspace menu's color row reads as one of the menu's items: its title starts where the
/// other items' titles start and is set in the same size. A capture of the shipped menu put the
/// other titles' ink 23 pt from the menu's edge in 13 pt type; this row's title sat 6 pt to the
/// left of them in 14 pt type.
@MainActor
struct WorkspaceColorSwatchRowTests {
    private let title = "Set Workspace Color"

    /// The title's inked columns, in points from the row's left edge.
    private func titleInk() throws -> ClosedRange<CGFloat> {
        let choices = ["Red", "Blue", "Green"].map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") }
        let row = WorkspaceColorSwatchView(title: title, choices: choices)
        row.frame.size.width = 360
        row.layout()
        let rep = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / row.bounds.width
        // The swatches sit at the right end; the title is everything left of the row's middle.
        let columns = (0..<rep.pixelsWide / 2).filter { x in
            (0..<rep.pixelsHigh).contains { y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 }
        }
        let first = try #require(columns.first), last = try #require(columns.last)
        return CGFloat(first) / scale...CGFloat(last + 1) / scale
    }

    @Test func startsWhereTheOtherItemsTitlesStart() throws {
        let ink = try titleInk()
        #expect((22...24).contains(ink.lowerBound), "title ink starts at \(ink.lowerBound) pt")
    }

    @Test func isSetInTheMenusTitleSize() throws {
        let ink = try titleInk()
        let native = (title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: NSFont.systemFontSize)]).width
        #expect(abs((ink.upperBound - ink.lowerBound) - native) <= 3, "title is \(ink.upperBound - ink.lowerBound) pt wide, menu titles \(native) pt")
    }
}
