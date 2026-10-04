import CoreGraphics
import Testing
@testable import CmuxNextRemoteView

struct RemoteViewGeometryTests {
    @Test func smallerFrameIsCenteredAtOnePixelPerPixel() {
        let geometry = RemoteViewGeometry(
            framePixels: CGSize(width: 2000, height: 1000), bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), backingScale: 2)
        #expect(geometry.imageRect == CGRect(x: 100, y: 150, width: 1000, height: 500))
        #expect(geometry.streamPixel(at: CGPoint(x: 100, y: 150))! == (0, 0))
        #expect(geometry.streamPixel(at: CGPoint(x: 100.5, y: 150.5))! == (1, 1))
        #expect(geometry.streamPixel(at: CGPoint(x: 1099.9, y: 649.9))! == (1999, 999))
        #expect(geometry.streamPixel(at: CGPoint(x: 50, y: 400)) == nil)
        #expect(geometry.clampedStreamPixel(at: CGPoint(x: 50, y: 1000)) == (0, 999))
    }

    @Test func largerFrameIsClippedFromTheTopLeftNeverScaled() {
        let geometry = RemoteViewGeometry(
            framePixels: CGSize(width: 3000, height: 2000), bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), backingScale: 2)
        #expect(geometry.imageRect == CGRect(x: 0, y: 0, width: 1500, height: 1000))
        #expect(geometry.streamPixel(at: CGPoint(x: 1199.5, y: 799.5))! == (2399, 1599))
    }

    @Test func oneXDisplayMapsPointsToPixels() {
        let geometry = RemoteViewGeometry(
            framePixels: CGSize(width: 800, height: 600), bounds: CGRect(x: 0, y: 0, width: 1000, height: 600), backingScale: 1)
        #expect(geometry.imageRect.origin == CGPoint(x: 100, y: 0))
        #expect(geometry.streamPixel(at: CGPoint(x: 500, y: 300))! == (400, 300))
        #expect(geometry.panePoint(forStreamPixel: 400, 300) == CGPoint(x: 500, y: 300))
    }

    @Test func originsSnapToDevicePixels() {
        // (1001 - 1000/2) / 2 = 250.25 points; at 2x that rounds to 250.5.
        let geometry = RemoteViewGeometry(
            framePixels: CGSize(width: 1000, height: 1000), bounds: CGRect(x: 0, y: 0, width: 1001, height: 500), backingScale: 2)
        #expect(geometry.imageRect.minX == 250.5)
    }
}

private func == (lhs: (x: Int32, y: Int32), rhs: (Int32, Int32)) -> Bool {
    lhs.x == rhs.0 && lhs.y == rhs.1
}
