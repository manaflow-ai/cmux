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
        #expect(abs(layout.webViewBounds.width - layout.bounds.width) < 0.000_01)
        #expect(abs(layout.webViewBounds.height - layout.bounds.height) < 0.000_01)
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
        #expect(abs(layout.webViewBounds.width - 1_600) < 0.000_01)
        #expect(abs(layout.webViewBounds.height - 900) < 0.000_01)
        #expect(layout.frame == CGRect(x: 0, y: 75, width: 800, height: 450))
        #expect(layout.scale == 0.625)
    }

    @Test(arguments: [1.0, 1.1])
    func emulatedViewportSurvivesDownwardAppKitRounding(pageZoom: Double) throws {
        let viewport = try #require(BrowserViewport(width: 1_280, height: 720))
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 380, height: 610),
            viewport: viewport,
            pageZoom: pageZoom
        ))

        let appKitRoundedWidth = layout.webViewBounds.width.nextDown
        let appKitRoundedHeight = layout.webViewBounds.height.nextDown
        #expect(Int((appKitRoundedWidth / pageZoom).rounded(.down)) == 1_280)
        #expect(Int((appKitRoundedHeight / pageZoom).rounded(.down)) == 720)
    }

    @Test func maximumViewportSurvivesWholePointWebKitQuantizationAtPageZoom() throws {
        let viewport = try #require(BrowserViewport(width: 4_096, height: 4_096))
        let pageZoom = 1.4
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            viewport: viewport,
            pageZoom: pageZoom
        ))

        let webKitQuantizedWidth = layout.webViewBounds.width.rounded(.down)
        let webKitQuantizedHeight = layout.webViewBounds.height.rounded(.down)
        #expect(Int((webKitQuantizedWidth / pageZoom).rounded(.down)) == 4_096)
        #expect(Int((webKitQuantizedHeight / pageZoom).rounded(.down)) == 4_096)
    }

    @Test func viewportSurvivesZoomProductJustAboveWholePoint() throws {
        let viewport = try #require(BrowserViewport(width: 4_096, height: 4_096))
        let pageZoom = (5_734.0 + 0.000_000_5) / 4_096.0
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            viewport: viewport,
            pageZoom: pageZoom
        ))

        let webKitQuantizedWidth = layout.webViewBounds.width.rounded(.down)
        #expect(Int((webKitQuantizedWidth / pageZoom).rounded(.down)) == 4_096)
    }

    @Test(arguments: [0.0, -Double.infinity, Double.infinity, Double.nan])
    func invalidPageZoomFallsBackToOne(pageZoom: Double) throws {
        let viewport = try #require(BrowserViewport(width: 375, height: 812))
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 375, height: 812),
            viewport: viewport,
            pageZoom: pageZoom
        ))

        #expect(abs(layout.webViewBounds.width - layout.bounds.width) < 0.000_01)
        #expect(abs(layout.webViewBounds.height - layout.bounds.height) < 0.000_01)
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

    @Test func nativeLayoutMatchesWebKitFractionalWidthQuantizationAtPageZoom() throws {
        let layout = try #require(BrowserViewportLayout(
            containerBounds: CGRect(x: 0, y: 0, width: 379.5, height: 610),
            viewport: nil,
            pageZoom: 1.1
        ))

        #expect(Int(layout.bounds.width.rounded(.down)) == 344)
        #expect(Int(layout.bounds.height.rounded(.down)) == 554)
        #expect(layout.webViewBounds == CGRect(x: 0, y: 0, width: 379.5, height: 610))
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

    @Test func nativeZoomSnapshotPlanNormalizesTilesInCSSPixels() throws {
        let plan = try #require(BrowserViewportSnapshotPlan(
            outputPixelSize: CGSize(width: 400, height: 300),
            backingScaleFactor: 2
        ))

        #expect(plan.snapshotPointWidth == 200)
        #expect(plan.outputPixelSize == CGSize(width: 400, height: 300))
        #expect(plan.canReuseSourcePixels(CGSize(width: 400, height: 300)))
        #expect(!plan.canReuseSourcePixels(CGSize(width: 800, height: 600)))
    }

    @Test func maximumSnapshotPlanReusesExactSourcePixels() throws {
        let plan = try #require(BrowserViewportSnapshotPlan(
            outputPixelSize: CGSize(width: 4_096, height: 4_096),
            backingScaleFactor: 2
        ))

        #expect(plan.outputPixelCount == BrowserViewportSnapshotPlan.maximumOutputPixelCount)
        #expect(plan.canReuseSourcePixels(CGSize(width: 4_096, height: 4_096)))
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
        #expect(metrics?.untransformedFullContentSnapshotRect(
            in: CGRect(x: 0, y: 0, width: 1_280, height: 720)
        ) == CGRect(x: 0, y: 0, width: 2_560, height: 2_160))
        #expect(metrics?.untransformedFullContentSnapshotRect(
            in: CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        ) == nil)
    }

    @Test func temporaryReparentingRestoresOnlyWhileItOwnsTheWebView() {
        let temporaryHost = BrowserViewportRestorationPolicy(
            temporaryHostIsCurrent: true,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: false
        )
        #expect(temporaryHost.shouldRestorePreviousHost)
        #expect(!temporaryHost.shouldPreservePreviousGeometry)

        let detached = BrowserViewportRestorationPolicy(
            temporaryHostIsCurrent: false,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: false
        )
        #expect(!detached.shouldRestorePreviousHost)

        let newerHost = BrowserViewportRestorationPolicy(
            temporaryHostIsCurrent: false,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: false
        )
        #expect(!newerHost.shouldRestorePreviousHost)

        let inspectorLayout = BrowserViewportRestorationPolicy(
            temporaryHostIsCurrent: true,
            hasPreviousHost: true,
            hasVisibleWebKitCompanion: true
        )
        #expect(inspectorLayout.shouldPreservePreviousGeometry)

        let detachedPreviousHost = BrowserViewportRestorationPolicy(
            temporaryHostIsCurrent: true,
            hasPreviousHost: false,
            hasVisibleWebKitCompanion: false
        )
        #expect(detachedPreviousHost.shouldPreservePreviousGeometry)
    }
}
