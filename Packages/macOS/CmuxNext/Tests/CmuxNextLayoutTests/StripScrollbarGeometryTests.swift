import CoreGraphics
import Testing
@testable import CmuxNextLayout

/// Strip scrollbar thumb geometry (dock-column.md, B1 to B3).
@Suite struct StripScrollbarGeometryTests {
    let track = CGRect(x: 0, y: 0, width: 500, height: 4)

    private func thumb(_ offset: CGFloat, content: CGFloat = 2000, viewport: CGFloat = 1000) -> CGRect? {
        StripScrollbarGeometry.thumb(track: track, offset: offset, contentWidth: content, viewportWidth: viewport, minimumThumbWidth: 24)
    }

    @Test func noThumbWhenEveryColumnFits() {
        #expect(thumb(0, content: 1000) == nil)
        #expect(thumb(0, content: 1000.4) == nil)
    }

    @Test func theThumbIsTheVisibleShareAndTracksTheOffset() {
        #expect(thumb(0) == CGRect(x: 0, y: 0, width: 250, height: 4))
        #expect(thumb(500) == CGRect(x: 125, y: 0, width: 250, height: 4))
        #expect(thumb(1000) == CGRect(x: 250, y: 0, width: 250, height: 4))
    }

    @Test func aLongStripKeepsAGrabbableThumb() {
        #expect(thumb(0, content: 100_000)?.width == 24)
    }

    @Test func rubberBandShortensTheThumbAtThatEnd() {
        #expect(thumb(-100) == CGRect(x: 0, y: 0, width: 225, height: 4))
        let past = thumb(1100)
        #expect(past?.width == 225)
        #expect(past?.maxX == 500)
    }

    @Test func draggingTheThumbMapsBackToAnOffset() {
        #expect(StripScrollbarGeometry.offset(forThumbMinX: 125, thumbWidth: 250, track: track, maxOffset: 1000) == 500)
        #expect(StripScrollbarGeometry.offset(forThumbMinX: -40, thumbWidth: 250, track: track, maxOffset: 1000) == 0)
        #expect(StripScrollbarGeometry.offset(forThumbMinX: 400, thumbWidth: 250, track: track, maxOffset: 1000) == 1000)
    }

    @Test func aTrackClickPagesToTheNearestSnap() {
        let snaps: [CGFloat] = [0, 300, 600, 1000]
        let thumbAt0 = CGRect(x: 0, y: 0, width: 250, height: 4)
        #expect(StripScrollbarGeometry.pageTarget(clickX: 400, thumb: thumbAt0, offset: 0, viewportWidth: 1000, snaps: snaps) == 1000)
        let thumbAt300 = CGRect(x: 75, y: 0, width: 250, height: 4)
        #expect(StripScrollbarGeometry.pageTarget(clickX: 10, thumb: thumbAt300, offset: 300, viewportWidth: 1000, snaps: snaps) == 0)
        #expect(StripScrollbarGeometry.pageTarget(clickX: 100, thumb: thumbAt300, offset: 300, viewportWidth: 1000, snaps: snaps) == nil)
        // A page shorter than half a snap step still moves one step.
        #expect(StripScrollbarGeometry.pageTarget(clickX: 400, thumb: thumbAt0, offset: 0, viewportWidth: 100, snaps: snaps) == 300)
    }
}
