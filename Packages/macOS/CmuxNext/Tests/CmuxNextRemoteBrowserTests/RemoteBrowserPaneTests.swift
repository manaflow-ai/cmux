import CoreGraphics
import Testing
@testable import CmuxNextRemoteBrowser
import CmuxNextRemoteView

#if DEBUG
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RemoteBrowserPaneTests {
    @Test func viewportIsWholeCssPixelsAtTheBackingScale() {
        let viewport = RemoteBrowserViewport(bounds: CGSize(width: 800.6, height: 600.2), backingScale: 2)
        #expect(viewport.cssWidth == 800)
        #expect(viewport.cssHeight == 600)
        #expect(viewport.scale == 2)
        #expect(viewport.pixelWidth == 1600)
        #expect(viewport.pixelHeight == 1200)
    }

    @Test func viewportNeverReportsAnEmptyPage() {
        let viewport = RemoteBrowserViewport(bounds: .zero, backingScale: 0)
        #expect(viewport.cssWidth == 1)
        #expect(viewport.cssHeight == 1)
        #expect(viewport.scale == 1)
    }

    @Test func framesFromTheStreamSourceReachThePresenterAtStreamSize() async throws {
        let source = MockRemoteStreamSource(width: 1280, height: 720)
        try #require(source.canEncode, "no H.264 encoder on this Mac")
        let pane = RemoteBrowserPane(source: source)
        let sizes = pane.frameSizes()
        pane.start()
        source.damage()
        var first: CGSize?
        for await size in sizes {
            first = size
            break
        }
        #expect(first == CGSize(width: 1280, height: 720))
        #expect(pane.view.video.framePixels == CGSize(width: 1280, height: 720))
        pane.stop()
    }
}
#endif
