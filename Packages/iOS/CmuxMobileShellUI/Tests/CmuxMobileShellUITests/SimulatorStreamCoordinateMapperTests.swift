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

    @Test func mapsBottomKeyboardPointUsingDisplayRegionHeight() throws {
        let mapper = SimulatorStreamCoordinateMapper(
            viewSize: CGSize(width: 430, height: 760),
            imageSize: CGSize(width: 1290, height: 2796)
        )

        let rect = mapper.fittedImageRect
        let expected = CGPoint(x: 0.88, y: 0.92)
        let point = try #require(mapper.normalizedPoint(from: CGPoint(
            x: rect.minX + (rect.width * expected.x),
            y: rect.minY + (rect.height * expected.y)
        )))

        #expect(abs(point.x - expected.x) < 0.0001)
        #expect(abs(point.y - expected.y) < 0.0001)
    }

    @Test func smallTapEndsAtTouchDownPoint() {
        let start = CGPoint(x: 372, y: 708)
        let location = CGPoint(x: 375, y: 704)

        let policy = SimulatorStreamTouchPointPolicy()
        #expect(policy.endPoint(start: start, location: location) == start)
        #expect(!policy.isDrag(start: start, location: location))
    }

    @Test func dragEndsAtFinalPoint() {
        let start = CGPoint(x: 120, y: 180)
        let location = CGPoint(x: 190, y: 300)

        let policy = SimulatorStreamTouchPointPolicy()
        #expect(policy.endPoint(start: start, location: location) == location)
        #expect(policy.isDrag(start: start, location: location))
    }
}
