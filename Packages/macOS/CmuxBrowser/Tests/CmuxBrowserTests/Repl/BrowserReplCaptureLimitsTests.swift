import Foundation
import Testing

@testable import CmuxBrowser

/// `tab.screenshot` and `tab.pdf` take sizes from the agent; the app renders
/// them on the main actor, so one capture must not be able to allocate
/// gigabytes or lay a page out over a mile of paper.
@Suite struct BrowserReplCaptureLimitsTests {
    let limits = BrowserReplCaptureLimits()

    static func code(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch let error as BrowserReplDriverError {
            return error.code
        } catch {
            return "unexpected"
        }
    }

    @Test func aScreenshotPastThePixelBudgetIsRefused() {
        // Each edge is within the 16,384 pixel edge limit; together they
        // are a gigabyte of pixels.
        let huge = CGRect(x: 0, y: 0, width: 16_384, height: 16_384)
        #expect(Self.code { try limits.checkScreenshot(region: huge, zoom: 1) } == "invalid")
        // A full page within the budget, but zoomed past it.
        let page = CGRect(x: 0, y: 0, width: 1_280, height: 16_384)
        #expect(Self.code { try limits.checkScreenshot(region: page, zoom: 1) } == nil)
        #expect(Self.code { try limits.checkScreenshot(region: page, zoom: 3) } == "invalid")
        #expect(Self.code { try limits.checkScreenshot(region: CGRect(x: 0, y: 0, width: 1_280, height: 800), zoom: 2) } == nil)
    }

    @Test func aScreenshotOfANonFiniteRegionIsRefused() {
        #expect(Self.code { try limits.checkScreenshot(region: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), zoom: 1) } == "invalid")
        #expect(Self.code { try limits.checkScreenshot(region: CGRect(x: 0, y: -CGFloat.infinity, width: 10, height: 10), zoom: 1) } == "invalid")
    }

    @Test func aPDFPaperPastTheLimitIsRefused() {
        let none = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        #expect(Self.code { try limits.checkPDF(paper: CGSize(width: 612, height: 792), margins: none) } == nil)
        // A0 fits.
        #expect(Self.code { try limits.checkPDF(paper: CGSize(width: 2_384, height: 3_370), margins: none) } == nil)
        for paper in [
            CGSize(width: 1e9, height: 792),
            CGSize(width: 612, height: 1e7),
            CGSize(width: 0, height: 792),
            CGSize(width: -612, height: 792),
            CGSize(width: CGFloat.nan, height: 792),
            CGSize(width: 612, height: CGFloat.infinity),
        ] {
            #expect(Self.code { try limits.checkPDF(paper: paper, margins: none) } == "invalid", "accepted \(paper)")
        }
    }

    @Test func pdfMarginsThatLeaveNoPageAreRefused() {
        let letter = CGSize(width: 612, height: 792)
        #expect(Self.code { try limits.checkPDF(paper: letter, margins: NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)) } == nil)
        for margins in [
            NSEdgeInsets(top: 0, left: 400, bottom: 0, right: 400),
            NSEdgeInsets(top: 1e9, left: 0, bottom: 0, right: 0),
            NSEdgeInsets(top: -10, left: 0, bottom: 0, right: 0),
            NSEdgeInsets(top: 0, left: CGFloat.nan, bottom: 0, right: 0),
        ] {
            #expect(Self.code { try limits.checkPDF(paper: letter, margins: margins) } == "invalid", "accepted \(margins)")
        }
    }
}
