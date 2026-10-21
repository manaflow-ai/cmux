import AppKit
import Testing
@testable import CmuxNextDesign

/// A chat's tools share its pane's tab row only when they fit in the half of the row the strip
/// gives up (`PaneTabRowSharing.fitsTabRow(room:)`). Before, the strip gave up at most half the row
/// while the page drew its tools at full width from the right, so in a narrow pane the leading
/// tools slid under the last tab, which drew over them and took their clicks.
@MainActor
struct PaneTabRowFitTests {
    final class Tools: PaneTabRowSharing {
        var tabRowToolsWidth: CGFloat?
        var tabRowToolsNeed: CGFloat?
        var onTabRowToolsChange: (() -> Void)?
        func setTabRow(height: CGFloat, trailingInset: CGFloat) {}
    }

    @Test func toolsWiderThanHalfTheRowKeepTheirOwnRow() {
        let tools = Tools()
        tools.tabRowToolsNeed = 220
        #expect(!tools.fitsTabRow(room: 400))
        #expect(tools.fitsTabRow(room: 440))
    }

    @Test func toolsThatNeverReportedAreOfferedTheRow() {
        let tools = Tools()
        #expect(tools.fitsTabRow(room: 100))
    }

    /// The page reports 0 once the row ends; the need it last reported keeps deciding, so a narrow
    /// pane does not offer the row again and loop.
    @Test func theNeedOutlivesTheRow() {
        let tools = Tools()
        tools.tabRowToolsNeed = 300
        tools.tabRowToolsWidth = 0
        #expect(!tools.fitsTabRow(room: 500))
        #expect(tools.tabRowWidth(room: 500) == 0)
    }
}
