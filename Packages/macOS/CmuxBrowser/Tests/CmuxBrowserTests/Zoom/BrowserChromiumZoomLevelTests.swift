import Testing
@testable import CmuxBrowser

@Suite struct BrowserChromiumZoomLevelTests {
    @Test func factorsAndLevelsRoundTrip() {
        #expect(BrowserChromiumZoomLevel(factor: 1).level == 0)
        #expect(abs(BrowserChromiumZoomLevel(factor: 1.2).level - 1) < 1e-9)
        #expect(abs(BrowserChromiumZoomLevel(level: -1).factor - 1 / 1.2) < 1e-9)
        for factor in [0.25, 0.5, 0.9, 1.1, 1.5, 3.0, 5.0] {
            #expect(abs(BrowserChromiumZoomLevel(factor: factor).factor - factor) < 1e-9)
        }
    }

    @Test func invalidInputsMeanActualSize() {
        #expect(BrowserChromiumZoomLevel(factor: 0).level == 0)
        #expect(BrowserChromiumZoomLevel(factor: -2).level == 0)
        #expect(BrowserChromiumZoomLevel(factor: .infinity).level == 0)
        #expect(BrowserChromiumZoomLevel(factor: .nan).level == 0)
        #expect(BrowserChromiumZoomLevel(level: .nan).factor == 1)
    }
}

@Suite struct BrowserZoomLadderTests {
    private let ladder = BrowserZoomLadder()

    @Test func stepsAlongChromePresets() {
        #expect(ladder.zoomIn(from: 1.0) == 1.1)
        #expect(ladder.zoomOut(from: 1.0) == 0.9)
        #expect(ladder.zoomIn(from: 1.1) == 1.25)
        #expect(ladder.zoomOut(from: 0.33) == 0.25)
    }

    @Test func offLadderFactorsSnapInTheStepDirection() {
        #expect(ladder.zoomIn(from: 1.17) == 1.25)
        #expect(ladder.zoomOut(from: 1.17) == 1.1)
        #expect(ladder.zoomIn(from: 1.0004) == 1.1)
    }

    @Test func endsClampAndInvalidInputResets() {
        #expect(ladder.zoomIn(from: 5.0) == 5.0)
        #expect(ladder.zoomOut(from: 0.25) == 0.25)
        #expect(ladder.clamp(9) == 5.0)
        #expect(ladder.clamp(0.1) == 0.25)
        #expect(ladder.zoomIn(from: .nan) == 1)
        #expect(BrowserZoomLadder.percent(1.25) == 125)
        #expect(BrowserZoomLadder.percent(0.33) == 33)
        #expect(BrowserZoomLadder(levels: []).levels == BrowserZoomLadder.chromePresets)
    }
}
