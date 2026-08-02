import CoreGraphics
import Testing
@testable import CmuxMobileShellUI

@Suite struct SimulatorStreamCoordinateMapperTests {
    @Test func mapsAspectFitPointToNormalizedSimulatorCoordinates() throws {
        let mapper = SimulatorStreamCoordinateMapper(
            viewSize: CGSize(width: 400, height: 400),
            imageSize: CGSize(width: 200, height: 400)
        )

        let point = try #require(mapper.normalizedPoint(from: CGPoint(x: 200, y: 200)))
        #expect(abs(point.x - 0.5) < 0.0001)
        #expect(abs(point.y - 0.5) < 0.0001)
    }

    @Test func clampsDragOutsideDisplayedImageToNearestSimulatorEdge() throws {
        let mapper = SimulatorStreamCoordinateMapper(
            viewSize: CGSize(width: 400, height: 400),
            imageSize: CGSize(width: 200, height: 400)
        )

        let point = try #require(mapper.normalizedPoint(from: CGPoint(x: 20, y: 500)))
        #expect(point.x == 0)
        #expect(point.y == 1)
    }
}
