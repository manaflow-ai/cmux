import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingFrameGeometryTests {
    private func plan(
        windowPixelWidth: Int = 1600,
        windowPixelHeight: Int = 1000,
        pointPixelScale: Double = 2,
        params: [String: Any] = [:]
    ) throws -> WindowRecordingFrameGeometry {
        try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: windowPixelWidth,
            windowPixelHeight: windowPixelHeight,
            pointPixelScale: pointPixelScale,
            request: try WindowRecordingRequest.make(params: params)
        )
    }

    @Test func mp4OfAWholeWindowKeepsItsPixels() throws {
        let geometry = try plan()

        #expect(geometry.cropX == 0)
        #expect(geometry.cropY == 0)
        #expect(geometry.cropWidth == 1600)
        #expect(geometry.cropHeight == 1000)
        #expect(geometry.outputWidth == 1600)
        #expect(geometry.outputHeight == 1000)
        #expect(geometry.scalesNothing)
    }

    @Test func mp4DimensionsStayEvenForH264() throws {
        let geometry = try plan(
            windowPixelWidth: 1001,
            windowPixelHeight: 667,
            params: ["scale": 0.5]
        )

        #expect(geometry.outputWidth % 2 == 0)
        #expect(geometry.outputHeight % 2 == 0)
        #expect(geometry.outputWidth == 500)
        #expect(geometry.outputHeight == 334)
    }

    @Test func gifIsHalvedAndWidthCappedByDefault() throws {
        let geometry = try plan(params: ["format": "gif"])

        #expect(geometry.outputWidth == 800)
        #expect(geometry.outputHeight == 500)
    }

    @Test func gifWidthCapKeepsTheAspectRatio() throws {
        let geometry = try plan(
            windowPixelWidth: 3200,
            windowPixelHeight: 2000,
            params: ["format": "gif"]
        )

        #expect(geometry.outputWidth == 960)
        #expect(geometry.outputHeight == 600)
    }

    @Test func regionPointsBecomePixelsOnARetinaWindow() throws {
        let geometry = try plan(params: ["region": "100,50,400,300"])

        #expect(geometry.cropX == 200)
        #expect(geometry.cropY == 100)
        #expect(geometry.cropWidth == 800)
        #expect(geometry.cropHeight == 600)
        #expect(geometry.outputWidth == 800)
        #expect(geometry.outputHeight == 600)
        #expect(!geometry.cropsNothing)
    }

    @Test func regionOnAOnePointPerPixelWindowIsNotScaled() throws {
        let geometry = try plan(pointPixelScale: 1, params: ["region": "10,10,100,100"])

        #expect(geometry.cropX == 10)
        #expect(geometry.cropWidth == 100)
    }

    @Test func aRegionHangingOffTheEdgeIsClampedToTheWindow() throws {
        let geometry = try plan(params: ["region": "700,400,400,400"])

        #expect(geometry.cropX == 1400)
        #expect(geometry.cropY == 800)
        #expect(geometry.cropWidth == 200)
        #expect(geometry.cropHeight == 200)
    }

    @Test func aRegionFullyOutsideTheWindowFails() throws {
        let request = try WindowRecordingRequest.make(params: ["region": "2000,0,100,100"])

        #expect(throws: WindowRecordingFrameGeometry.Failure.regionOutsideWindow) {
            try WindowRecordingFrameGeometry.plan(
                windowPixelWidth: 1600,
                windowPixelHeight: 1000,
                pointPixelScale: 1,
                request: request
            )
        }
    }

    @Test func anEmptyWindowFails() throws {
        #expect(throws: WindowRecordingFrameGeometry.Failure.emptyWindow) {
            try plan(windowPixelWidth: 0)
        }
    }

    @Test func aBrokenPixelScaleFallsBackToOnePixelPerPoint() throws {
        let geometry = try plan(pointPixelScale: 0, params: ["region": "10,10,100,100"])

        #expect(geometry.cropX == 10)
        #expect(geometry.cropWidth == 100)
    }

    @Test func outputNeverCollapsesToZero() throws {
        let geometry = try plan(
            windowPixelWidth: 10,
            windowPixelHeight: 10,
            params: ["scale": 0.1]
        )

        #expect(geometry.outputWidth == 2)
        #expect(geometry.outputHeight == 2)
    }

    @Test func aResizedWindowKeepsTheEncodedFrameSize() throws {
        let opening = try plan(windowPixelWidth: 1000, windowPixelHeight: 800)
        let resized = try plan(windowPixelWidth: 1200, windowPixelHeight: 700)

        let continued = opening.adoptingCrop(of: resized)

        #expect(continued.cropWidth == 1200)
        #expect(continued.cropHeight == 700)
        #expect(continued.outputWidth == opening.outputWidth)
        #expect(continued.outputHeight == opening.outputHeight)
    }
}
