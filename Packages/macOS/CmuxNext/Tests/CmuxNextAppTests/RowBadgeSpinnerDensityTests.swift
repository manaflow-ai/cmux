import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-03, on the compact sidebar: "i think the spinners are maybe a bit too big in this situation".
/// At every sidebar density and minimal mode, a row's working spinner fits its trailing slot and is never larger
/// than the row's leading icon or the warning mark, and it stays on the slot's center.
@MainActor @Suite struct RowBadgeSpinnerDensityTests {
    nonisolated static let cases: [(SidebarDensity, SidebarMinimalMode)] = SidebarDensity.allCases.flatMap { density in
        SidebarMinimalMode.allCases.map { (density, $0) }
    }

    @Test(arguments: 0..<cases.count)
    func theSpinnerFitsTheTrailingSlot(index: Int) throws {
        let (density, minimal) = Self.cases[index]
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try SidebarGroupRailAlignmentTests.with(density, minimal) {
            let view = RowBadgeView(frame: NSRect(x: 0, y: 0, width: 60, height: SidebarLayoutMetrics.standard.rowHeight))
            view.configure([.working], look: .corner)
            view.layoutSubtreeIfNeeded()
            let spinner = try #require(view.glyphFrames.first)
            let label = "\(density)/\(minimal): \(spinner)"
            #expect(spinner.width <= view.cellSide && spinner.height <= view.cellSide, "\(label) overflows its slot")
            #expect(spinner.width <= SidebarStyle.leadingGlyphSide, "\(label) is larger than the leading icon")
            #expect(spinner.width < RowBadgeView.markSide, "\(label) is as large as the warning")
            #expect(spinner.width <= SidebarStyle.statusGlyphSize, "\(label) is larger than the row's status glyph")
            let cellMid = ((view.bounds.height - view.cellSide) / 2).rounded() + view.cellSide / 2
            #expect(abs(spinner.midX - view.cellSide / 2) < 0.01 && abs(spinner.midY - cellMid) < 0.01, "\(label) is off center")
        }
    }
}
