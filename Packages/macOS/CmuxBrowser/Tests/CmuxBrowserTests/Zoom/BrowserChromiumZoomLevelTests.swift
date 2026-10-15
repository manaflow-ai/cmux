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
