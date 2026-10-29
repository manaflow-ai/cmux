import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowScreenshotRequestTests {
    @Test func emptyParametersAreACompletePNGRequest() throws {
        let request = try WindowScreenshotRequest.make(params: [:])

        #expect(request.format == .png)
        #expect(request.target == .window)
        #expect(request.windowHandle == nil)
        #expect(request.scale == 1)
        #expect(request.maximumWidth == nil)
        // Empty, not "screenshot": the naming helper leaves the component out
        // and the file is named by its timestamp alone, as a recording is.
        #expect(request.label == "")
        #expect(request.outputPath == nil)
        #expect(request.caption == nil)
    }

    @Test func jpgNamesTheJPEGFormat() throws {
        // What a caller types and what the file is called, against what the
        // image type is called.
        #expect(try WindowScreenshotRequest.make(params: ["format": " JPG "]).format == .jpeg)
        #expect(try WindowScreenshotRequest.make(params: ["format": "jpeg"]).format == .jpeg)
    }

    @Test func aJPEGPathMayUseEitherSpelling() throws {
        for path in ["/tmp/shot.jpg", "/tmp/shot.JPEG"] {
            let request = try WindowScreenshotRequest.make(params: [
                "format": "jpg",
                "out": path,
            ])
            #expect(request.outputPath == path)
        }
        #expect(WindowScreenshotRequest.Format.jpeg.preferredFileExtension == "jpg")
    }

    @Test func aPathMustNameTheFormatItWillHold() throws {
        // A .png full of JPEG bytes is a file every later tool misreads, so the
        // mismatch is refused rather than silently renamed.
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["format": "jpeg", "out": "/tmp/shot.png"])
        }
        #expect(failure == .outputExtensionMismatch(path: "/tmp/shot.png", format: .jpeg))
        #expect(failure?.message == "out '/tmp/shot.png' must end in .jpg or .jpeg for format jpeg")
    }

    @Test func aRelativePathIsRefusedBecauseTheAppIsNotInTheCallersDirectory() throws {
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["out": "shot.png"])
        }
        #expect(failure == .outputPathNotAbsolute("shot.png"))
    }

    @Test func anUnknownFormatListsTheOnesThatWork() throws {
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["format": "webp"])
        }
        #expect(failure == .unknownFormat("webp"))
        #expect(failure?.message == "unknown format 'webp'; expected one of png, jpeg")
    }

    @Test func explicitValuesOverrideTheDefaults() throws {
        let request = try WindowScreenshotRequest.make(params: [
            "format": "jpg",
            "scale": 0.5,
            "max_width": 1200,
            "quality": 0.4,
            "window": " window:2 ",
            "label": "settings sheet!",
            "caption": "  the sheet  ",
        ])

        #expect(request.scale == 0.5)
        #expect(request.maximumWidth == 1200)
        #expect(request.quality == 0.4)
        #expect(request.windowHandle == "window:2")
        #expect(request.label == "settings-sheet")
        #expect(request.caption == "the sheet")
    }

    @Test func numbersArriveAsStringsFromACLICaller() throws {
        let request = try WindowScreenshotRequest.make(params: [
            "scale": "0.25",
            "max_width": "800",
            "quality": "0.9",
        ])

        #expect(request.scale == 0.25)
        #expect(request.maximumWidth == 800)
        #expect(request.quality == 0.9)
    }

    @Test func anOutOfRangeValueNamesItsLimits() throws {
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["max_width": 32])
        }
        #expect(failure?.message == "max_width must be between 64 and 8192")
        // A still may be wider than a recording's cap: one png of a 6K window is
        // a reasonable thing to ask for, 30 of them a second is not.
        #expect(try WindowScreenshotRequest.make(params: ["max_width": 8192]).maximumWidth == 8192)
    }

    @Test func directConstructionEnforcesCaptureBounds() {
        #expect(throws: WindowScreenshotRequest.Failure.outOfRange(field: "scale", message: "must be between 0.1 and 1")) {
            try WindowScreenshotRequest(scale: .nan)
        }
        #expect(throws: WindowScreenshotRequest.Failure.outOfRange(field: "quality", message: "must be between 0.1 and 1")) {
            try WindowScreenshotRequest(quality: .infinity)
        }
        #expect(throws: WindowScreenshotRequest.Failure.outOfRange(field: "max_width", message: "must be between 64 and 8192")) {
            try WindowScreenshotRequest(maximumWidth: 32)
        }
        #expect(throws: WindowScreenshotRequest.Failure.regionTooLarge) {
            try WindowScreenshotRequest(target: .region(WindowRecordingRegion(x: 1e300, y: 0, width: 100, height: 100)))
        }
    }

    @Test func aHugeNumberIsOutOfRangeRatherThanATrap() throws {
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["max_width": 1e30])
        }
        #expect(failure?.message == "max_width must be between 64 and 8192")
    }

    @Test func fractionalMaximumWidthsAreRejectedInsteadOfRounded() {
        for value: Any in [799.5, "799.5"] {
            let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
                try WindowScreenshotRequest.make(params: ["max_width": value])
            }
            #expect(failure?.message == "max_width must be a whole number between 64 and 8192")
        }
    }

    @Test func nonNumbersAreRefusedByName() throws {
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["quality": "sharp"])
        }
        #expect(failure == .notANumber(field: "quality"))
    }

    @Test func aRegionArrivesAsTextOrAsAnArray() throws {
        let fromText = try WindowScreenshotRequest.make(params: ["region": "10,20,300,200"])
        let fromArray = try WindowScreenshotRequest.make(params: ["region": [10, 20, 300, 200]])

        #expect(fromText.target == .region(WindowRecordingRegion(x: 10, y: 20, width: 300, height: 200)))
        #expect(fromText.target == fromArray.target)
    }

    @Test func regionArraysRequireExactlyFourNumericElements() {
        #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["region": [0, 0, 100, 100, "ignored"]])
        }
        #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["region": [0, false, 100, 100]])
        }
    }

    @Test func aRegionTooSmallToSeeIsRefused() throws {
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["region": "0,0,4,4"])
        }
        #expect(failure == .regionTooSmall)
        #expect(failure?.message == "region width and height must each be at least 8 points")
    }

    @Test func hugeFiniteRegionsAreRejectedRatherThanReachingIntegerConversion() {
        #expect(throws: WindowScreenshotRequest.Failure.regionTooLarge) {
            try WindowScreenshotRequest.make(params: ["region": [0, 0, 1e300, 1e300]])
        }
        #expect(throws: WindowScreenshotRequest.Failure.regionTooLarge) {
            try WindowScreenshotRequest.make(params: ["region": [1e300, 0, 100, 100]])
        }
    }

    @Test func aMalformedRegionQuotesWhatWasGiven() throws {
        let failure = #expect(throws: WindowScreenshotRequest.Failure.self) {
            try WindowScreenshotRequest.make(params: ["region": "10,20,300"])
        }
        #expect(failure == .malformedRegion("10,20,300"))
    }

    @Test func anUnusableLabelIsFiledAsAScreenshotRatherThanARecording() throws {
        let request = try WindowScreenshotRequest.make(params: ["label": "!!!"])

        #expect(request.label == "screenshot")
    }

    @Test func qualityOnlyMeansSomethingForALossyFormat() {
        #expect(WindowScreenshotRequest.Format.jpeg.isLossy)
        #expect(!WindowScreenshotRequest.Format.png.isLossy)
    }
}
