import Testing

@testable import CmuxBrowser

@Suite struct BrowserDesignModeAnnotationCaptureTests {
    @Test func expandsStrokeBoundsWithComfortableContextPadding() {
        let capture = BrowserDesignModeAnnotationCapture(contextPadding: 48)

        let rect = capture.contextRect(
            around: BrowserDesignModeRect(x: 120, y: 90, width: 240, height: 160),
            in: BrowserDesignModeViewport(width: 800, height: 600)
        )

        #expect(rect == BrowserDesignModeRect(x: 72, y: 42, width: 336, height: 256))
    }

    @Test func clampsExpandedContextToEveryViewportEdge() {
        let capture = BrowserDesignModeAnnotationCapture(contextPadding: 48)

        let rect = capture.contextRect(
            around: BrowserDesignModeRect(x: 12, y: 18, width: 780, height: 570),
            in: BrowserDesignModeViewport(width: 800, height: 600)
        )

        #expect(rect == BrowserDesignModeRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func returnsAnEmptyRectForAnInvalidViewport() {
        let capture = BrowserDesignModeAnnotationCapture(contextPadding: 48)

        let rect = capture.contextRect(
            around: BrowserDesignModeRect(x: 10, y: 10, width: 100, height: 100),
            in: BrowserDesignModeViewport(width: 0, height: 600)
        )

        #expect(rect == BrowserDesignModeRect(x: 0, y: 0, width: 0, height: 0))
    }
}
