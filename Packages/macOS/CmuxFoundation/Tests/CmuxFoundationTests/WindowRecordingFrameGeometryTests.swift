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
        #expect(!geometry.cropsNothing(ofWidth: 1600, height: 1000))
    }

    @Test func aRegionAtTheWindowOriginStillCrops() throws {
        let geometry = try plan(params: ["region": "0,0,420,900"])

        #expect(geometry.cropX == 0)
        #expect(geometry.cropY == 0)
        #expect(geometry.cropWidth == 840)
        #expect(geometry.cropHeight == 1000)
        #expect(!geometry.cropsNothing(ofWidth: 1600, height: 1000))
        #expect(try plan().cropsNothing(ofWidth: 1600, height: 1000))
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

    @Test func publicRequestsRejectRegionsThatCouldOverflowPixelArithmetic() {
        #expect(throws: WindowRecordingRequest.Failure.regionTooLarge) {
            try WindowRecordingRequest(
                target: .region(WindowRecordingRegion(x: 0, y: 0, width: 1e300, height: 1e300))
            )
        }
        #expect(throws: WindowRecordingRequest.Failure.regionTooLarge) {
            try WindowRecordingRequest(
                target: .region(WindowRecordingRegion(x: 1e300, y: 0, width: 100, height: 100))
            )
        }
    }

    @Test func gifFramesHaveAPixelQuotaIndependentOfWidth() throws {
        let request = try WindowRecordingRequest(
            format: .gif,
            scale: 1,
            maximumWidth: .some(WindowRecordingRequest.gifMaximumWidth)
        )

        #expect(throws: WindowRecordingFrameGeometry.Failure.gifFrameTooLarge) {
            try WindowRecordingFrameGeometry.plan(
                windowPixelWidth: 1280,
                windowPixelHeight: 4000,
                pointPixelScale: 1,
                request: request
            )
        }
    }

    /// A clip's encoded size is fixed by its first frame, so a window that grows
    /// past the gif pixel ceiling mid-clip has to be cropped into that size
    /// rather than ending the recording over a size nothing encodes.
    @Test func aMidClipCropIgnoresTheGIFPixelCeiling() throws {
        let request = try WindowRecordingRequest(
            format: .gif,
            scale: 1,
            maximumWidth: .some(WindowRecordingRequest.gifMaximumWidth)
        )

        let planned = try WindowRecordingFrameGeometry.planCrop(
            windowPixelWidth: 1280,
            windowPixelHeight: 4000,
            pointPixelScale: 1,
            request: request
        )

        #expect(planned.cropWidth == 1280)
        #expect(planned.cropHeight == 4000)
    }

    /// The one resize that still ends a clip: a region the window has shrunk
    /// out of has no rectangle left to sample.
    @Test func aMidClipCropStillFailsForARegionOutsideTheWindow() throws {
        let request = try WindowRecordingRequest.make(params: ["region": "900,20,200,100"])

        #expect(throws: WindowRecordingFrameGeometry.Failure.regionOutsideWindow) {
            try WindowRecordingFrameGeometry.planCrop(
                windowPixelWidth: 400,
                windowPixelHeight: 300,
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

    @Test func aStillAndAClipCropTheSameRegionToTheSamePixels() throws {
        // `cmux shot --region` and `cmux record --region` share this planner so
        // the same four numbers cannot mean two rectangles.
        let region = WindowRecordingRegion(x: 10, y: 20, width: 301, height: 200)
        let clip = try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: 2000,
            windowPixelHeight: 1600,
            pointPixelScale: 2,
            request: try WindowRecordingRequest.make(params: [
                "format": "gif",
                "region": "10,20,301,200",
                "scale": 1,
            ])
        )
        let still = try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: 2000,
            windowPixelHeight: 1600,
            pointPixelScale: 2,
            region: region,
            scale: 1,
            maximumWidth: nil,
            widthQuantum: 1
        )

        #expect(still.cropX == clip.cropX)
        #expect(still.cropY == clip.cropY)
        #expect(still.cropWidth == clip.cropWidth)
        #expect(still.cropHeight == clip.cropHeight)
    }

    @Test func anOddWidthSurvivesAStillButNotAnMP4Frame() throws {
        // H.264 wants even dimensions and a still does not, which is the only
        // thing the quantum changes.
        func width(quantum: Int) throws -> Int {
            try WindowRecordingFrameGeometry.plan(
                windowPixelWidth: 1001,
                windowPixelHeight: 800,
                pointPixelScale: 1,
                region: nil,
                scale: 1,
                maximumWidth: nil,
                widthQuantum: quantum
            ).outputWidth
        }

        #expect(try width(quantum: 1) == 1001)
        #expect(try width(quantum: 2) == 1000)
    }

    @Test func aNonsenseQuantumIsTreatedAsOne() throws {
        let geometry = try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: 1001,
            windowPixelHeight: 800,
            pointPixelScale: 1,
            region: nil,
            scale: 1,
            maximumWidth: nil,
            widthQuantum: 0
        )

        #expect(geometry.outputWidth == 1001)
    }
}
