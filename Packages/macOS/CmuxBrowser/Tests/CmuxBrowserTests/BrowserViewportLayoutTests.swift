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
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            viewport: viewport
        ))

        #expect(layout.mode == .emulated)
        #expect(layout.frame == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(layout.bounds == CGRect(x: 0, y: 0, width: 1_280, height: 720))
        #expect(layout.webViewBounds == layout.bounds)
        #expect(layout.scale == 0.625)
    }

    @Test func pageZoomExpandsOnlyAppKitBounds() throws {
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            viewport: viewport,
            pageZoom: 1.25
        ))

        #expect(layout.bounds == CGRect(x: 0, y: 0, width: 1_280, height: 720))
        #expect(layout.webViewBounds == CGRect(x: 0, y: 0, width: 1_600, height: 900))
        #expect(layout.frame == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(layout.scale == 0.625)
    }

    @Test(arguments: [0.0, -Double.infinity, Double.infinity, Double.nan])
    func invalidPageZoomFallsBackToOne(pageZoom: Double) throws {
        let viewport = try #require(BrowserViewport(width: 375, height: 812))
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 375, height: 812),
            viewport: viewport,
            pageZoom: pageZoom
        ))

        #expect(layout.webViewBounds == layout.bounds)
    }

    @Test func tallViewportCentersInsideWidePane() throws {
        let viewport = try #require(BrowserViewport(width: 375, height: 812))
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 20, y: 10, width: 1_000, height: 600),
            viewport: viewport
        ))

        let expectedScale = 600.0 / 812.0
        #expect(layout.mode == .emulated)
        #expect(abs(layout.scale - expectedScale) < 0.000_001)
        #expect(abs(layout.frame.midX - 520) < 0.000_001)
        #expect(abs(layout.frame.minY - 10) < 0.000_001)
        #expect(abs(layout.frame.height - 600) < 0.000_001)
        #expect(layout.bounds.size == CGSize(width: 375, height: 812))
    }

    @Test func nativeLayoutFillsContainerAtOneToOneScale() throws {
        let container = CGRect(x: 4, y: 8, width: 798, height: 534)
        let layout = try #require(BrowserViewportLayout(containerBounds: container, viewport: nil))

        #expect(layout.mode == .native)
        #expect(layout.frame == container)
        #expect(layout.bounds == CGRect(origin: .zero, size: container.size))
        #expect(layout.webViewBounds == layout.bounds)
        #expect(layout.scale == 1)
    }

    @Test func nativeLayoutReportsZoomAdjustedCSSViewport() throws {
        let container = CGRect(x: 4, y: 8, width: 800, height: 600)
        let layout = try #require(BrowserViewportLayout(
            containerBounds: container,
            viewport: nil,
            pageZoom: 2
        ))

        #expect(layout.frame == container)
        #expect(layout.bounds == CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(layout.webViewBounds == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(layout.scale == 2)
    }

    @Test func renderLimitsBoundCombinedViewportAndZoomGeometry() throws {
        let limits = BrowserViewportRenderLimits.standard
        let commonViewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let maximumViewport = try #require(BrowserViewport(width: 4_096, height: 4_096))

        #expect(limits.supports(viewport: commonViewport, pageZoom: 5))
        #expect(limits.supports(viewport: maximumViewport, pageZoom: 1))
        #expect(!limits.supports(viewport: maximumViewport, pageZoom: 5))
        #expect(abs(limits.maximumPageZoom(for: maximumViewport) - 2.0.squareRoot()) < 0.000_001)
        #expect(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            viewport: maximumViewport,
            pageZoom: 5
        ) == nil)
    }

    @Test func retinaSnapshotPlanRequestsExactCSSPixelOutput() throws {
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let plan = BrowserViewportSnapshotPlan(viewport: viewport, backingScaleFactor: 2)

        #expect(plan.snapshotPointWidth == 640)
        #expect(plan.outputPixelSize == CGSize(width: 1_280, height: 720))
        #expect(plan.outputPixelCount == 921_600)
        #expect(plan.outputPixelCount <= BrowserViewportSnapshotPlan.maximumOutputPixelCount)
    }

    @Test func fullPageTilePlanRejectsExcessiveCaptureCount() throws {
        #expect(BrowserFullPageTilePlan(
            contentSize: CGSize(width: 1_000, height: 1_000),
            viewportSize: CGSize(width: 1, height: 1)
        ) == nil)

        let plan = try #require(BrowserFullPageTilePlan(
            contentSize: CGSize(width: 4_096, height: 4_096),
            viewportSize: CGSize(width: 512, height: 512)
        ))
        #expect(plan.columnCount == 8)
        #expect(plan.rowCount == 8)
        #expect(plan.tileCount == 64)
        #expect(plan.origin(column: 7, row: 7) == CGPoint(x: 3_584, y: 3_584))
    }

    @Test func contentMetricsKeepReportedCSSViewportAtPageZoom() {
        let metrics = BrowserViewportContentMetrics(
            contentSize: CGSize(width: 2_560, height: 2_160),
            reportedViewportSize: CGSize(width: 1_280, height: 720),
            fallbackViewportSize: CGSize(width: 1_600, height: 900),
            scrollOffset: CGPoint(x: 10, y: 20)
        )

        #expect(metrics?.viewportSize == CGSize(width: 1_280, height: 720))
        #expect(metrics?.scrollOffset == CGPoint(x: 10, y: 20))
    }

    @Test func temporaryReparentingRestoresOnlyWhileItOwnsTheWebView() {
        let temporaryHost = BrowserViewportRestorationPolicy(
            hasCurrentHost: true,
            temporaryHostIsCurrent: true,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: false
        )
        #expect(temporaryHost.shouldRestorePreviousHost)
        #expect(!temporaryHost.shouldPreservePreviousGeometry)

        let detached = BrowserViewportRestorationPolicy(
            hasCurrentHost: false,
            temporaryHostIsCurrent: false,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: false
        )
        #expect(detached.shouldRestorePreviousHost)

        let newerHost = BrowserViewportRestorationPolicy(
            hasCurrentHost: true,
            temporaryHostIsCurrent: false,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: false
        )
        #expect(!newerHost.shouldRestorePreviousHost)

        let inspectorLayout = BrowserViewportRestorationPolicy(
            hasCurrentHost: true,
            temporaryHostIsCurrent: true,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: true
        )
        #expect(inspectorLayout.shouldPreservePreviousGeometry)

        let detachedPreviousHost = BrowserViewportRestorationPolicy(
            hasCurrentHost: true,
            temporaryHostIsCurrent: true,
            hasPreviousHost: false,
            hasVisibleWebKitCompanion: false
        )
        #expect(detachedPreviousHost.shouldPreservePreviousGeometry)
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

    @Test func attachedInspectorResetsEmulatedViewport() throws {
        let model = BrowserViewportModel()
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))

        model.setViewport(viewport)
        #expect(model.resetForAttachedInspector())
        #expect(model.viewport == nil)
        #expect(!model.resetForAttachedInspector())
    }
}
