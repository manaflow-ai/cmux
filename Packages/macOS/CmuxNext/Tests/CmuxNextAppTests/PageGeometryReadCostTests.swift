import AppKit
@testable import CmuxNextBrowser
@testable import CmuxNextLayout
import Testing

/// Review 1 of PL-motion-cef batch 1 (finding 4): the fork reads a moving page's occlusion rects and
/// clip several times per display frame (once per ancestor frame notification). Recording what it
/// read (`CEFHostGeometry`, for skipping page update requests that change nothing) walked the host's
/// ancestors once more for the clip inputs on every read. One fork update (its occlusion read, then
/// its clip read) works the clip inputs out once per read, as before the record was added.
@MainActor @Suite struct PageGeometryReadCostTests {
    @Test func oneForkUpdateWalksTheAncestorsOncePerRead() {
        let page = CEFHostView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let host = PaneHostView(pane: PaneID("browser"), content: page)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.applyShape(padding: 8, cornerRadius: 10)
        host.layoutSubtreeIfNeeded()
        let before = CEFHostView.trackerStats.clipInputWalks
        _ = page.cmuxOcclusionRects()
        _ = page.cmuxClipPath()
        #expect(CEFHostView.trackerStats.clipInputWalks - before == 2, "one walk per fork read")
    }
}
