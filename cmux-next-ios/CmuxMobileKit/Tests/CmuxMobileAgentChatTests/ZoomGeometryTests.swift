import CmuxMobileArtifacts
import CoreGraphics
import Testing

/// Round 3 review N2: double-tap zooms to 2.5x around the tapped point and back to fit;
/// small images are centered. (Simulator HID double-taps do not reach the viewer.)
@Suite struct ZoomGeometryTests {
    let geometry = ZoomGeometry()
    let viewport = CGSize(width: 402, height: 874)

    @Test func doubleTapAtFitZoomsToTwoAndAHalfAroundThePoint() throws {
        let tap = CGPoint(x: 100, y: 300)
        let rect = try #require(geometry.doubleTapTarget(scale: 1, tap: tap, viewSize: viewport))
        #expect(abs(viewport.width / rect.width - 2.5) < 0.001)
        #expect(abs(viewport.height / rect.height - 2.5) < 0.001)
        #expect(rect.midX == tap.x && rect.midY == tap.y)
    }

    @Test func doubleTapWhenZoomedReturnsToFit() {
        #expect(geometry.doubleTapTarget(scale: 2.5, tap: .zero, viewSize: viewport) == nil)
        #expect(geometry.isZoomed(2.5))
        #expect(!geometry.isZoomed(1))
    }

    @Test func smallContentIsCentered() {
        let insets = geometry.centeringInsets(content: CGSize(width: 402, height: 302), viewport: viewport)
        #expect(insets.horizontal == 0 && insets.vertical == 286)
    }
}
