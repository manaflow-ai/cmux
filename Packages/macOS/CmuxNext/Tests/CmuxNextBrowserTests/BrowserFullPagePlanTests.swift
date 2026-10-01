import CoreGraphics
import Testing
@testable import CmuxNextBrowser

/// A stitched full-page screenshot visits every viewport-sized tile of the
/// document, row by row, and refuses pages it cannot hold.
@Suite struct BrowserFullPagePlanTests {
    @Test func coversTheDocumentRowByRow() throws {
        let plan = try #require(BrowserFullPagePlan(contentSize: CGSize(width: 1200, height: 2500),
                                                    viewportSize: CGSize(width: 1000, height: 1000)))
        #expect(plan.origins == [
            CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 0),
            CGPoint(x: 0, y: 1000), CGPoint(x: 1000, y: 1000),
            CGPoint(x: 0, y: 2000), CGPoint(x: 1000, y: 2000),
        ])
    }

    @Test func aPageThatFitsIsOneTile() throws {
        let plan = try #require(BrowserFullPagePlan(contentSize: CGSize(width: 800, height: 600), viewportSize: CGSize(width: 800, height: 600)))
        #expect(plan.origins == [.zero])
    }

    @Test func refusesEmptyNonFiniteAndHugePages() {
        let viewport = CGSize(width: 800, height: 600)
        #expect(BrowserFullPagePlan(contentSize: .zero, viewportSize: viewport) == nil)
        #expect(BrowserFullPagePlan(contentSize: CGSize(width: 800, height: .infinity), viewportSize: viewport) == nil)
        #expect(BrowserFullPagePlan(contentSize: CGSize(width: 800, height: 600), viewportSize: .zero) == nil)
        #expect(BrowserFullPagePlan(contentSize: CGSize(width: 10_000, height: 10_001), viewportSize: viewport) == nil)
        #expect(!BrowserFullPagePlan.isCapturable(contentSize: CGSize(width: 5_000, height: 5_001)))
        #expect(BrowserFullPagePlan.isCapturable(contentSize: CGSize(width: 1_280, height: 19_000)))
    }

    @Test func refusesMoreTilesThanTheDeadlineAllows() {
        // 1280x60000 in an 800x600 viewport is 2 x 100 tiles.
        #expect(BrowserFullPagePlan(contentSize: CGSize(width: 1_280, height: 60_000), viewportSize: CGSize(width: 800, height: 600)) == nil)
        #expect(BrowserFullPagePlan(contentSize: CGSize(width: 800, height: 600), viewportSize: CGSize(width: 0.5, height: 0.5)) == nil)
    }

    @Test func theLastTileScrollsOnlyAsFarAsThePageCan() throws {
        let plan = try #require(BrowserFullPagePlan(contentSize: CGSize(width: 1_000, height: 2_500), viewportSize: CGSize(width: 1_000, height: 1_000)))
        #expect(plan.expectedScroll(for: CGPoint(x: 0, y: 2_000)) == CGPoint(x: 0, y: 1_500))
        #expect(plan.expectedScroll(for: CGPoint(x: 0, y: 1_000)) == CGPoint(x: 0, y: 1_000))
    }
}
