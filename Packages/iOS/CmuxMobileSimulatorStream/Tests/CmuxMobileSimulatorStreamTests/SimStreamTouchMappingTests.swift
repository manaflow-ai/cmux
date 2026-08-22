import CoreGraphics
import Testing

@testable import CmuxMobileSimulatorStream

@Suite
struct SimStreamTouchMappingTests {
    @Test
    func tallVideoInWideBoundsPillarboxes() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let rect = SimStreamTouchMapping.videoRect(
            pixelSize: CGSize(width: 100, height: 200), in: bounds)
        #expect(rect == CGRect(x: 100, y: 0, width: 200, height: 400))
    }

    @Test
    func centerOfVideoMapsToCenterNormalized() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let point = SimStreamTouchMapping.normalizedPoint(
            CGPoint(x: 200, y: 200), pixelSize: CGSize(width: 100, height: 200), in: bounds)
        #expect(point == CGPoint(x: 0.5, y: 0.5))
    }

    @Test
    func letterboxTouchesAreNil() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)
        let point = SimStreamTouchMapping.normalizedPoint(
            CGPoint(x: 10, y: 200), pixelSize: CGSize(width: 100, height: 200), in: bounds)
        #expect(point == nil)
    }

    @Test
    func degenerateGeometryIsSafe() {
        #expect(
            SimStreamTouchMapping.videoRect(pixelSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10))
                == .zero)
        #expect(
            SimStreamTouchMapping.normalizedPoint(
                .zero, pixelSize: CGSize(width: 10, height: 10), in: .zero) == nil)
    }
}
