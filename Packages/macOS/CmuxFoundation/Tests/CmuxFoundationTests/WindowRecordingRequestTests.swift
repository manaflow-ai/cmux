import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct WindowRecordingRequestTests {
    @Test func emptyParametersAreACompleteMP4Request() throws {
        let request = try WindowRecordingRequest.make(params: [:])

        #expect(request.format == .mp4)
        #expect(request.target == .window)
        #expect(request.windowHandle == nil)
        #expect(request.framesPerSecond == 12)
        #expect(request.maximumSeconds == 15)
        #expect(request.scale == 1)
        #expect(request.maximumWidth == nil)
        #expect(request.drawsCaptions)
        #expect(request.frameBudget == 180)
    }

    @Test func gifDefaultsStaySmallerThanMP4Defaults() throws {
        let request = try WindowRecordingRequest.make(params: ["format": "GIF"])

        #expect(request.format == .gif)
        #expect(request.framesPerSecond == 8)
        #expect(request.scale == 0.5)
        #expect(request.maximumWidth == 960)
    }

    @Test func explicitValuesOverrideFormatDefaults() throws {
        let request = try WindowRecordingRequest.make(params: [
            "format": "gif",
            "fps": 15,
            "scale": 0.75,
            "max_width": 640,
            "max_seconds": 4.5,
            "captions": false,
            "window": " window:2 ",
            "label": "settings tour!",
        ])

        #expect(request.framesPerSecond == 15)
        #expect(request.scale == 0.75)
        #expect(request.maximumWidth == 640)
        #expect(request.maximumSeconds == 4.5)
        #expect(!request.drawsCaptions)
        #expect(request.windowHandle == "window:2")
        #expect(request.label == "settings-tour")
        #expect(request.frameBudget == 68)
    }

    @Test func numbersArriveAsStringsFromV1Callers() throws {
        let request = try WindowRecordingRequest.make(params: [
            "fps": "6",
            "max_seconds": "2",
            "captions": "no",
        ])

        #expect(request.framesPerSecond == 6)
        #expect(request.maximumSeconds == 2)
        #expect(!request.drawsCaptions)
        #expect(request.frameBudget == 12)
    }

    @Test func regionAcceptsTextAndArrayForms() throws {
        let fromText = try WindowRecordingRequest.make(params: ["region": "10, 20,300,200"])
        let fromArray = try WindowRecordingRequest.make(params: ["region": [10, 20, 300, 200]])
        let expected = WindowRecordingRegion(x: 10, y: 20, width: 300, height: 200)

        #expect(fromText.target == .region(expected))
        #expect(fromArray.target == .region(expected))
    }

    @Test func regionArraysRequireExactlyFourNumericElements() {
        #expect(throws: Never.self) {
            _ = try WindowRecordingRequest.make(params: [
                "region": [
                    NSNumber(value: 0),
                    NSNumber(value: 0),
                    NSNumber(value: 100),
                    NSNumber(value: 100),
                ],
            ])
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest.make(params: ["region": [0, 0, 100, 100, "ignored"]])
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest.make(params: [
                "region": [0, NSNumber(value: true), 100, 100],
            ])
        }
    }

    @Test(arguments: [
        "10,20,300",
        "10,20,300,200,5",
        "",
        "a,b,c,d",
    ])
    func malformedRegionsAreRejected(region: String) {
        #expect(throws: WindowRecordingRequest.Failure.malformedRegion(region)) {
            try WindowRecordingRequest.make(params: ["region": region])
        }
    }

    @Test func tinyRegionsAreRejected() {
        #expect(throws: WindowRecordingRequest.Failure.regionTooSmall) {
            try WindowRecordingRequest.make(params: ["region": "0,0,4,200"])
        }
    }

    @Test func nonFiniteRegionsAreRejected() {
        #expect(throws: (any Error).self) {
            try WindowRecordingRequest.make(params: ["region": [0, 0, Double.infinity, 200]])
        }
    }

    @Test func hugeFiniteRegionsAreRejectedRatherThanReachingIntegerConversion() {
        #expect(throws: WindowRecordingRequest.Failure.regionTooLarge) {
            try WindowRecordingRequest.make(params: ["region": [0, 0, 1e300, 1e300]])
        }
        #expect(throws: WindowRecordingRequest.Failure.regionTooLarge) {
            try WindowRecordingRequest.make(params: ["region": [1e300, 0, 100, 100]])
        }
    }

    @Test func unknownFormatsNameTheKnownOnes() throws {
        let failure = WindowRecordingRequest.Failure.unknownFormat("webm")

        #expect(throws: failure) {
            try WindowRecordingRequest.make(params: ["format": "webm"])
        }
        #expect(failure.message == "unknown format 'webm'; expected one of mp4, gif")
    }

    @Test(arguments: [
        ("fps", 0),
        ("fps", 61),
        ("max_width", 8),
    ])
    func outOfRangeIntegersAreRejected(field: String, value: Int) {
        #expect(throws: (any Error).self) {
            try WindowRecordingRequest.make(params: [field: value])
        }
    }

    @Test func fractionalFrameRatesAreRejectedInsteadOfRounded() {
        for value: Any in [12.5, "12.5"] {
            let failure = #expect(throws: WindowRecordingRequest.Failure.self) {
                try WindowRecordingRequest.make(params: ["fps": value])
            }
            #expect(failure?.message == "fps must be a whole number between 1 and 30")
        }
    }

    @Test func fractionalMaximumWidthsAreRejectedInsteadOfRounded() {
        for value: Any in [639.5, "639.5"] {
            #expect(throws: WindowRecordingRequest.Failure.self) {
                try WindowRecordingRequest.make(params: ["max_width": value])
            }
        }
    }

    @Test func durationIsCappedSoAStuckAgentCannotFillTheDisk() {
        #expect(throws: (any Error).self) {
            try WindowRecordingRequest.make(params: ["max_seconds": 3600])
        }
        #expect(WindowRecordingRequest.allowedSeconds.upperBound == 120)
    }

    @Test func scaleNeverUpscales() {
        #expect(WindowRecordingRequest.allowedScale.upperBound == 1)
        #expect(throws: (any Error).self) {
            try WindowRecordingRequest.make(params: ["scale": 2])
        }
    }

    @Test func nonNumericValuesSayWhichField() {
        #expect(throws: WindowRecordingRequest.Failure.notANumber(field: "fps")) {
            try WindowRecordingRequest.make(params: ["fps": "soon"])
        }
    }

    /// `Int(Double.nan)` and `Int(1e30)` trap, which takes the whole app down,
    /// and `cmux record --fps nan` hands exactly those values to this decoder.
    @Test(arguments: ["nan", "inf", "-inf", "1e30", "-1e30"])
    func numbersThatCannotBeAnIntegerAreRejectedRatherThanTrapping(text: String) {
        #expect(throws: (any Error).self) {
            try WindowRecordingRequest.make(params: ["fps": text])
        }
        #expect(throws: (any Error).self) {
            try WindowRecordingRequest.make(params: ["max_width": text])
        }
        #expect(throws: (any Error).self) {
            try WindowRecordingRequest.make(params: ["max_seconds": text])
        }
    }

    @Test func outputPathMustBeAbsoluteAndMatchTheFormat() {
        #expect(throws: WindowRecordingRequest.Failure.outputPathNotAbsolute("clip.mp4")) {
            try WindowRecordingRequest.make(params: ["out": "clip.mp4"])
        }
        #expect(throws: WindowRecordingRequest.Failure.outputExtensionMismatch(
            path: "/tmp/clip.mov",
            format: .mp4
        )) {
            try WindowRecordingRequest.make(params: ["out": "/tmp/clip.mov"])
        }
    }

    @Test func outputPathIsKeptWhenItMatches() throws {
        let request = try WindowRecordingRequest.make(params: [
            "format": "gif",
            "out": "/tmp/tour/clip.GIF",
        ])

        #expect(request.outputPath == "/tmp/tour/clip.GIF")
    }

    @Test func frameIntervalFollowsTheFrameRate() throws {
        let request = try WindowRecordingRequest.make(params: ["fps": 10])

        #expect(request.frameInterval == 0.1)
    }

    @Test func publicInitializerEnforcesNumericInvariants() {
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(framesPerSecond: 0)
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(maximumSeconds: .nan)
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(maximumSeconds: .infinity)
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(scale: 0)
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(maximumWidth: .some(8))
        }
    }

    @Test func publicInitializerKeepsGIFBudgetsBounded() {
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(
                format: .gif,
                framesPerSecond: 30,
                maximumSeconds: 120
            )
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(format: .gif, maximumWidth: .some(nil))
        }
        #expect(throws: WindowRecordingRequest.Failure.self) {
            try WindowRecordingRequest(
                format: .gif,
                maximumWidth: .some(WindowRecordingRequest.gifMaximumWidth + 1)
            )
        }
    }

    @Test func publicInitializerNormalizesFilesystemAndWindowFields() throws {
        let request = try WindowRecordingRequest(
            windowHandle: "  window:2  ",
            label: " feature/settings! "
        )

        #expect(request.windowHandle == "window:2")
        #expect(request.label == "feature-settings")
    }
}
