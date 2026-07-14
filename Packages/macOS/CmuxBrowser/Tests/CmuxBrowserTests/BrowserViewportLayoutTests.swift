import CoreGraphics
import Testing
@testable import CmuxBrowser

@Suite("Browser viewport layout")
struct BrowserViewportLayoutTests {
    @Test func viewportDimensionsMustFitSupportedRange() {
        #expect(BrowserViewport(width: 1, height: 1) != nil)
        #expect(BrowserViewport(width: 4_096, height: 4_096) != nil)
        #expect(BrowserViewport(width: 0, height: 720) == nil)
        #expect(BrowserViewport(width: 1_280, height: 0) == nil)
        #expect(BrowserViewport(width: 4_097, height: 720) == nil)
        #expect(BrowserViewport(width: 1_280, height: 4_097) == nil)
    }

    @Test func wideViewportAspectFitsWithoutChangingLogicalBounds() throws {
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let layout = BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            viewport: viewport
        )

        #expect(layout.mode == .emulated)
        #expect(layout.frame == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(layout.bounds == CGRect(x: 0, y: 0, width: 1_280, height: 720))
        #expect(layout.scale == 0.625)
    }

    @Test func tallViewportCentersInsideWidePane() throws {
        let viewport = try #require(BrowserViewport(width: 375, height: 812))
        let layout = BrowserViewportLayout(
            containerBounds: CGRect(x: 20, y: 10, width: 1_000, height: 600),
            viewport: viewport
        )

        let expectedScale = 600.0 / 812.0
        #expect(layout.mode == .emulated)
        #expect(abs(layout.scale - expectedScale) < 0.000_001)
        #expect(abs(layout.frame.midX - 520) < 0.000_001)
        #expect(abs(layout.frame.minY - 10) < 0.000_001)
        #expect(abs(layout.frame.height - 600) < 0.000_001)
        #expect(layout.bounds.size == CGSize(width: 375, height: 812))
    }

    @Test func nativeLayoutFillsContainerAtOneToOneScale() {
        let container = CGRect(x: 4, y: 8, width: 798, height: 534)
        let layout = BrowserViewportLayout(containerBounds: container, viewport: nil)

        #expect(layout.mode == .native)
        #expect(layout.frame == container)
        #expect(layout.bounds == CGRect(origin: .zero, size: container.size))
        #expect(layout.scale == 1)
    }
}

@Suite("Browser viewport model")
@MainActor
struct BrowserViewportModelTests {
    @Test func setAndResetPreserveOneViewportSourceOfTruth() throws {
        let model = BrowserViewportModel()
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))

        #expect(model.viewport == nil)
        #expect(model.setViewport(viewport))
        #expect(model.viewport == viewport)
        #expect(!model.setViewport(viewport))
        #expect(model.setViewport(nil))
        #expect(model.viewport == nil)
    }
}
