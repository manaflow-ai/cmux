import CoreGraphics
import Testing
@testable import CmuxMobileBrowserStream

@Suite struct BrowserStreamTransformTests {
    @Test func fitsWidthAndRoundTripsPagePoints() throws {
        let transform = BrowserStreamTransform(
            viewSize: CGSize(width: 390, height: 844),
            pageSize: CGSize(width: 780, height: 1200)
        )
        #expect(transform.fitScale == 0.5)
        let viewPoint = try #require(transform.viewPoint(fromPagePoint: CGPoint(x: 390, y: 600)))
        #expect(viewPoint == CGPoint(x: 195, y: 422))
        let pagePoint = try #require(transform.pagePoint(fromViewPoint: viewPoint))
        #expect(abs(pagePoint.x - 390) < 0.001)
        #expect(abs(pagePoint.y - 600) < 0.001)
    }

    @Test func phoneReflowWidthDisplaysAtOneToOneScale() {
        let transform = BrowserStreamTransform(
            viewSize: CGSize(width: 393, height: 740),
            pageSize: CGSize(width: 393, height: 740)
        )
        #expect(transform.fitScale == 1)
    }

    @Test func localZoomAndPanPreserveInvertibility() throws {
        let transform = BrowserStreamTransform(
            viewSize: CGSize(width: 400, height: 800),
            pageSize: CGSize(width: 800, height: 1200),
            zoomScale: 2,
            viewportOffset: CGPoint(x: 40, y: 75)
        )
        let original = CGPoint(x: 315, y: 480)
        let displayed = try #require(transform.viewPoint(fromPagePoint: original))
        let roundTrip = try #require(transform.pagePoint(fromViewPoint: displayed))
        #expect(abs(roundTrip.x - original.x) < 0.001)
        #expect(abs(roundTrip.y - original.y) < 0.001)
    }

    @Test func scrollDeltaUsesFitScaleAndIgnoresLocalLensScale() {
        let transform = BrowserStreamTransform(
            viewSize: CGSize(width: 400, height: 700),
            pageSize: CGSize(width: 800, height: 1000),
            zoomScale: 3
        )
        #expect(transform.pageDelta(fromViewDelta: CGPoint(x: 5, y: 20)) == CGPoint(x: 10, y: 40))
    }

    @Test func letterboxPointsDoNotBecomeEdgeClicks() {
        let transform = BrowserStreamTransform(
            viewSize: CGSize(width: 400, height: 800),
            pageSize: CGSize(width: 800, height: 400)
        )
        #expect(transform.displayedPageRect == CGRect(x: 0, y: 300, width: 400, height: 200))
        #expect(transform.pagePoint(fromViewPoint: CGPoint(x: 200, y: 100)) == nil)
        #expect(transform.pagePoint(fromViewPoint: CGPoint(x: 200, y: 400)) == CGPoint(x: 400, y: 200))
    }
}
