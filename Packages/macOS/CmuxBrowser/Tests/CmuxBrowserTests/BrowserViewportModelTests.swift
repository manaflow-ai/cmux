import CoreGraphics
import Testing
@testable import CmuxBrowser

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

    @Test func attachedInspectorResetsEmulatedViewport() throws {
        let model = BrowserViewportModel()
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let inspectorContainerBounds = CGRect(x: 0, y: 0, width: 900, height: 640)

        model.setViewport(viewport)
        let nativeLayout = try #require(model.resetForAttachedInspector(
            containerBounds: inspectorContainerBounds,
            pageZoom: 2
        ))
        #expect(model.viewport == nil)
        #expect(nativeLayout.frame == inspectorContainerBounds)
        #expect(nativeLayout.webViewBounds == CGRect(x: 0, y: 0, width: 900, height: 640))
        #expect(model.resetForAttachedInspector(
            containerBounds: inspectorContainerBounds,
            pageZoom: 2
        ) == nil)
    }

    @Test func externalGeometrySuspendsAndRestoresEmulatedViewport() throws {
        let model = BrowserViewportModel()
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))

        model.setViewport(viewport)
        #expect(model.suspendForExternalGeometry())
        #expect(model.viewport == nil)
        #expect(model.requestedViewport == viewport)
        #expect(!model.suspendForExternalGeometry())

        #expect(model.resumeAfterExternalGeometry() == viewport)
        #expect(model.viewport == viewport)
        #expect(model.requestedViewport == viewport)
        #expect(model.resumeAfterExternalGeometry() == nil)
    }
}
