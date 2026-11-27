import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// A pinned workspace with no icon draws its color as its list row does: a dot before the title
/// (2026-10-25: a color picked on a pinned workspace showed nowhere on its tile).
@MainActor
struct SidebarPinnedTileColorTests {
    private static func row(color: GroupColor?) -> SidebarItemRowView {
        let row = SidebarItemRowView(frame: NSRect(x: 0, y: 0, width: 240, height: 32))
        var info = SidebarItemInfo(title: "workspace-4", symbol: "textformat", color: color)
        info.textOnly = true
        info.leadingPin = true
        row.configure(info, style: .list)
        row.layoutSubtreeIfNeeded()
        row.layout()
        return row
    }

    @Test func aColoredTextOnlyTileDrawsADotBeforeItsTitle() {
        let row = Self.row(color: .blue)
        #expect(row.showsSwatchDot)
        #expect(row.chip.frame.width == SidebarStyle.dotSize && row.chip.frame.height == SidebarStyle.dotSize)
        #expect(row.chip.cornerRadius == SidebarStyle.dotSize / 2, "a round dot")
        #expect(row.title.frame.minX >= row.chip.frame.maxX, "the title follows the dot")
    }

    @Test func anUncoloredTextOnlyTileDrawsNoDot() {
        let row = Self.row(color: nil)
        #expect(!row.showsSwatchDot)
        #expect(row.chip.frame == .zero)
    }
}
