import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextLayout
import Testing

/// Columns and chrome (Lawrence 2026-10-13, a screen recording: "there are layering issues for
/// columns + chrome"): while the column strip scrolled, a browser column's page drew over the
/// chat column and the sidebar. The strip clips a pane that scrolls under a docked column or
/// past the strip's edge with a layer mask (`PaneHostView.setStripClip`), but a Chromium page
/// is a child window: no layer mask reaches it, and the fork clips it only to the host's visible
/// rect, `cmuxClipPath` and `cmuxOcclusionRects`. Those two are what the fork reads, so they
/// must carry the strip clip.
@MainActor @Suite struct ColumnStripPageClipTests {
    /// A pane host as the layout makes it (8 pt padding, 10 pt corners) holding the browser's
    /// `CEFHostView`, the parent view the fork keeps the page window over.
    struct Column {
        let page = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let host: PaneHostView

        init() {
            host = PaneHostView(pane: PaneID("browser"), content: page)
            host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            host.applyShape(padding: 8, cornerRadius: 10)
            host.layoutSubtreeIfNeeded()
        }

        /// What the fork masks the page to.
        var shown: CGRect? { page.cmuxClipPath()?.bounds }
    }

    @Test func aColumnPartlyPastTheStripEdgeCutsItsPageAtThatEdge() throws {
        let column = Column()
        // The strip shows only the host's right 150 pt; the page starts 8 pt in.
        column.host.setStripClip(CGRect(x: 250, y: 0, width: 150, height: 300))
        let shown = try #require(column.shown, "the page is cut where the strip clips its column")
        let left = column.page.convert(CGPoint(x: 250, y: 0), from: column.host).x
        #expect(abs(shown.minX - left) < 1, "the page starts at the strip's edge: \(shown), edge \(left)")
        #expect(abs(shown.maxX - column.page.bounds.maxX) < 1, "\(shown)")
        #expect(column.page.cmuxOcclusionRects().count == 0, "a partly shown page is not hidden")
    }

    /// A band dock covers a pane's bottom: the clip is vertical, and the page (not flipped)
    /// must take it at its own bottom, not its top.
    @Test func aDockOverAColumnsBottomCutsThePageAtItsBottom() throws {
        let column = Column()
        // The host is flipped: y 0...200 is its top two thirds.
        column.host.setStripClip(CGRect(x: 0, y: 0, width: 400, height: 200))
        let shown = try #require(column.shown)
        let edge = column.page.convert(CGPoint(x: 0, y: 200), from: column.host).y
        #expect(abs(shown.minY - edge) < 1, "the page's bottom edge is the dock's top: \(shown), edge \(edge)")
        #expect(abs(shown.maxY - column.page.bounds.maxY) < 1, "\(shown)")
    }

    @Test func aColumnScrolledOutOfTheStripHidesItsPage() {
        let column = Column()
        column.host.setStripClip(.zero)
        #expect(column.page.cmuxClipPath() == nil)
        let holes = (column.page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
        #expect(holes == [column.page.bounds], "one hole over the whole page hides it: \(holes)")
    }

    @Test func aWholeColumnKeepsOnlyItsRoundedCorners() throws {
        let column = Column()
        column.host.setStripClip(nil)
        let shown = try #require(column.shown, "the pane's rounded corners still cut the page")
        #expect(abs(shown.width - column.page.bounds.width) < 1 && abs(shown.height - column.page.bounds.height) < 1, "\(shown)")
        #expect(column.page.cmuxOcclusionRects().count == 0)
    }
}
