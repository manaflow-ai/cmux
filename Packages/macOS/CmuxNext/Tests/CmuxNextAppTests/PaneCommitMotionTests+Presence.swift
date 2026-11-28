import AppKit
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// `PaneCommitMotionTests`, what the content of a pane that a zoom covers hears while the zoom's pane grows over it.
///
/// The covered panes show at their places under the pane that zooms until the motion's end (`keepsDeparted`), and the
/// part outside that pane's moving rect is on screen. Their content must go on drawing there: the app hides a page's
/// view and stops a terminal's drawing when its pane is reported hidden (`panePresenceDidChange`). The layout reported
/// them hidden in the frame that began the move, so a covered browser's page went blank there while its tab strip and
/// toolbar stayed over the window's backdrop, until the zooming pane reached them (the in-tree pages build, Nov 26).
extension PaneCommitMotionTests {
    /// The first frame after the zoom key and each frame of the move: the panes that the zoom covers are still reported
    /// visible. The frame that ends the motion hides them, and their content hears that they are hidden.
    @Test func aZoomsCoveredPanesStayVisibleToTheirContentUntilTheMotionEnds() throws {
        let zoom = try Self.zooming(frames: 0)
        defer { zoom.harness.window.closeAfterTest() }
        let harness = zoom.harness, screen = zoom.screen
        let covered = ["p1", "p2", "p3"] as [PaneID]
        for pane in covered {
            try #require(harness.provider.presence[pane] == .visible, "SETUP: \(pane) was not visible before the zoom")
        }
        _ = harness.root.advanceFrame(Self.dt)
        try #require(Self.inFlight(screen), "SETUP: the frame after the zoom key began no move")
        var frame = 1
        while Self.inFlight(screen), frame < Commit.frames {
            for pane in covered {
                let place = try #require(zoom.grid.panes[pane])
                let shown = Self.hosts(of: screen)[pane].map { !$0.isHidden && Commit.near($0.frame, place) } ?? false
                try #require(shown, "SETUP: \(pane) does not show at its place under the pane that zooms in frame \(frame)")
                #expect(harness.provider.presence[pane] == .visible,
                        "frame \(frame) of the zoom's move reports \(pane) \(String(describing: harness.provider.presence[pane])) while it shows under the pane that zooms: its page goes blank beside its tab strip")
            }
            _ = harness.root.advanceFrame(Self.dt)
            frame += 1
        }
        try #require(!Self.inFlight(screen), "SETUP: the zoom's move did not end in \(Commit.frames) frames")
        for pane in covered {
            #expect(harness.provider.presence[pane] == .hidden,
                    "after the motion's end \(pane), which the zoomed pane covers, is reported \(String(describing: harness.provider.presence[pane]))")
        }
    }
}
