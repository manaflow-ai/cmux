import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A zoomed pane shows whole once its zoom's motion ends: no strip-clip mask cuts it where a pane it covers was.
///
/// In the frame that shows a zoom, the panes it covers stay shown under it (`PaneCommitMotion.keepUnder`: their
/// layers go under the others, their views keep their order). The strip clips are made in that frame, from the panes
/// in front of each host (`ScreenContentView.panesAbove`): a covered pane later in view order counted as in front of
/// the pane that zooms, and its place was cut out of the zoomed pane's mask. The motion's end hid the covered panes
/// and made no clip again, so the cut stayed: the user's "Cmd-Shift-Enter is buggy, offset with black areas"; the
/// page-fit runs (2026-11-24, in-tree ON and OFF): a zoomed page pane dark from 228 to 762 pt, the place of the chat
/// pane it covered, for the whole 8 s recording.
extension PaneCommitMotionTests {
    @Test func aZoomedPaneShowsWholeAfterItsMotionWhateverPanesItCoveredCameAfterIt() throws {
        // p1 is first in the grid's view order: p2, p3 and p4, which it covers, come after it.
        let zoom = try Self.zooming(frames: 0, pane: "p1")
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        _ = harness.root.advanceFrame(Self.dt)
        _ = Self.toTheEnd(harness, screen)
        #expect(Self.restsZoomed(zoom), "SETUP: the zoom does not rest: \(Commit.shown(screen).panes)")
        let host = try #require(Self.hosts(of: screen)["p1"], "the zoomed pane does not show")
        let layer = try #require(host.layer)
        if let mask = layer.mask {
            let cuts = (mask as? StripClipMaskLayer)?.cutouts ?? []
            #expect(mask.frame.insetBy(dx: -0.5, dy: -0.5).contains(CGRect(origin: .zero, size: host.bounds.size)) && cuts.isEmpty,
                    "the zoomed pane is cut by a mask \(mask.frame) with cutouts \(cuts) in its \(host.bounds.size): a pane it covered stayed in front of it")
        }
    }
}
