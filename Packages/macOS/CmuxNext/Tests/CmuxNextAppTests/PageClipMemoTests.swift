import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextLayout
import Testing

/// Leo (2026-10-21, perf program): "i think we're frequently just recalculating too often, too
/// unnecessarily". The fork re-reads a page's clip and occlusion rects on every geometry update,
/// several per display frame while a pane moves and on window moves that move nothing. The clip
/// shape is worked out once per change of its inputs (the host's bounds, the clips and cutouts
/// of its ancestors) and the same shape answers every read until one changes; a change that
/// moves no frame (a strip clip, a corner radius) still gives the new shape.
@MainActor @Suite struct PageClipMemoTests {
    /// A pane host as the layout makes it (8 pt padding, 10 pt corners) holding the page's host view.
    struct Column {
        let page = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let host: PaneHostView

        init() {
            host = PaneHostView(pane: PaneID("browser"), content: page)
            host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            host.applyShape(padding: 8, cornerRadius: 10)
            host.layoutSubtreeIfNeeded()
        }
    }

    @Test func readsWithNothingChangedShareOneShape() throws {
        let column = Column()
        let builds = CEFHostView.trackerStats.clipBuilds
        let first = try #require(column.page.pageClip, "the pane's rounded corners cut the page")
        // One fork update reads both; a window move or key change reads them again.
        _ = column.page.cmuxOcclusionRects()
        let again = try #require(column.page.pageClip)
        let forFork = try #require(column.page.cmuxClipPath())
        #expect(first === again, "an unchanged page answers from its last shape")
        #expect(forFork === column.page.cmuxClipPath(), "the fork gets the same path object while nothing changed")
        #expect(CEFHostView.trackerStats.clipBuilds - builds == 1, "one shape for four reads")
    }

    @Test func repeatedOcclusionReadsReuseNormalizedRectsAndBridge() {
        let column = Column()
        let beforeBuilds = CEFHostView.trackerStats.occlusionBuilds
        let beforeHits = CEFHostView.trackerStats.occlusionHits
        let first = column.page.cmuxOcclusionRects()
        for _ in 0..<20 { _ = column.page.cmuxOcclusionRects() }
        #expect(first === column.page.cmuxOcclusionRects(), "the bridge is stable while geometry holds")
        #expect(CEFHostView.trackerStats.occlusionBuilds - beforeBuilds == 1)
        #expect(CEFHostView.trackerStats.occlusionHits - beforeHits >= 20)
    }

    @Test func occlusionChangeInvalidatesNormalizedRects() {
        let column = Column()
        _ = column.page.cmuxOcclusionRects()
        let before = CEFHostView.trackerStats.occlusionBuilds
        column.page.occlusionRects = [CGRect(x: 20, y: 20, width: 30, height: 30)]
        let holes = (column.page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
        #expect(holes == [CGRect(x: 20, y: 20, width: 30, height: 30)])
        #expect(CEFHostView.trackerStats.occlusionBuilds - before == 1)
    }

    /// A resize the fork learns of from AppKit, with no `postGeometryChange`, still rebuilds the
    /// holes on the next read: the memo is keyed on the geometry, not on posts.
    @Test func aResizeWithoutAPostRebuildsTheHoles() {
        let column = Column()
        _ = column.page.cmuxOcclusionRects()
        let before = CEFHostView.trackerStats.occlusionBuilds
        column.host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        column.host.layoutSubtreeIfNeeded()
        // No holes either way, and an empty NSArray bridges to one shared object: count builds.
        _ = column.page.cmuxOcclusionRects()
        #expect(CEFHostView.trackerStats.occlusionBuilds - before == 1)
    }

    @Test func aStripClipWithoutAFrameChangeGivesTheNewShape() throws {
        let column = Column()
        let whole = try #require(column.page.cmuxClipPath()?.bounds)
        // The strip shows only the host's right 150 pt; no frame moves.
        column.host.setStripClip(CGRect(x: 250, y: 0, width: 150, height: 300))
        let cut = try #require(column.page.cmuxClipPath()?.bounds)
        let edge = column.page.convert(CGPoint(x: 250, y: 0), from: column.host).x
        #expect(cut.width < whole.width - 100, "the shape follows the strip clip: \(whole) then \(cut)")
        #expect(abs(cut.minX - edge) < 1, "the page starts at the strip's edge: \(cut), edge \(edge)")
        column.host.setStripClip(.zero)
        #expect(column.page.cmuxClipPath() == nil, "a page scrolled out of the strip shows nothing")
        let holes = (column.page.cmuxOcclusionRects() as? [NSValue])?.map(\.rectValue) ?? []
        #expect(holes == [column.page.bounds], "one hole over the whole page hides it: \(holes)")
        column.host.setStripClip(nil)
        let back = try #require(column.page.cmuxClipPath()?.bounds)
        #expect(abs(back.width - whole.width) < 1 && abs(back.height - whole.height) < 1, "\(back) == \(whole)")
    }

    @Test func aCornerRadiusChangeGivesTheNewShape() throws {
        let column = Column()
        let rounded = try #require(column.page.pageClip)
        let builds = CEFHostView.trackerStats.clipBuilds
        column.host.applyShape(padding: 8, cornerRadius: 0)
        column.host.layoutSubtreeIfNeeded()
        let square = column.page.pageClip
        #expect(square !== rounded, "a new corner radius is a new shape")
        #expect(CEFHostView.trackerStats.clipBuilds - builds == 1)
        column.host.applyShape(padding: 8, cornerRadius: 10)
        column.host.layoutSubtreeIfNeeded()
        let roundedAgain = try #require(column.page.pageClip, "the corners cut the page again")
        #expect(roundedAgain !== square && roundedAgain.boundingBoxOfPath == rounded.boundingBoxOfPath)
    }

    @Test func aResizeGivesTheNewShape() throws {
        let column = Column()
        let before = try #require(column.page.pageClip).boundingBoxOfPath
        column.host.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        column.host.layoutSubtreeIfNeeded()
        let after = try #require(column.page.pageClip).boundingBoxOfPath
        #expect(after.width < before.width - 50, "the shape follows the narrower page: \(before) then \(after)")
        #expect(abs(after.width - column.page.bounds.width) < 1, "\(after) vs \(column.page.bounds)")
    }
}
