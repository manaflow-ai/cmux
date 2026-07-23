import CMUXMobileCore
import CoreGraphics
import Testing
@testable import CmuxMobileBrowserStream

@Suite struct BrowserStreamSurfaceStateTests {
    @Test @MainActor func acceptsLowSequenceAfterSubscriptionRestart() throws {
        let descriptor = MobileBrowserPanelDescriptor(
            panelID: "panel-1",
            workspaceID: "workspace-1",
            url: "https://example.com",
            title: "Example",
            pageWidth: 400,
            pageHeight: 300,
            canGoBack: false,
            canGoForward: false,
            isLoading: false
        )
        let state = BrowserStreamSurfaceState(descriptor: descriptor)
        let image = try #require(makeImage())
        state.didDisplay(BrowserStreamFrame(
            sequence: 42,
            image: image,
            pageSize: CGSize(width: 400, height: 300),
            pixelSize: CGSize(width: 800, height: 600)
        ))

        state.prepareForStreamStart()
        state.didDisplay(BrowserStreamFrame(
            sequence: 1,
            image: image,
            pageSize: CGSize(width: 400, height: 300),
            pixelSize: CGSize(width: 800, height: 600)
        ))

        #expect(state.latestFrame?.sequence == 1)
        #expect(state.streamStatus == .streaming)
    }

    private func makeImage() -> CGImage? {
        CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage()
    }
}
