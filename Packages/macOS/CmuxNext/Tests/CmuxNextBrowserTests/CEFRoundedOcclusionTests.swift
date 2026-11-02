import AppKit
@testable import CmuxNextBrowser
import Testing

/// Lawrence 2026-10-27 ("dialog sides has weird bg"): a Chromium page is a child window above the
/// chrome, so the save-password and find bars punch a hole in it. A square hole showed the pane
/// ground in the four corners outside the bars' rounded glass. The bars now leave the page's clip
/// shape as rounded holes: the page shows (and takes the mouse) around their corners, and the
/// bar shows (and takes the mouse) inside them.
@MainActor @Suite struct CEFRoundedOcclusionTests {
    static let page = CGRect(x: 0, y: 0, width: 800, height: 600)
    static let bar = CEFClipShape.RoundedRect(rect: CGRect(x: 100, y: 500, width: 600, height: 80), radius: 16)

    @Test func aRoundedBarLeavesThePageWithItsCorners() throws {
        let shape = try #require(CEFClipShape.path(bounds: Self.page, clips: [], roundedHoles: [Self.bar]))
        #expect(!shape.contains(CGPoint(x: 400, y: 540)), "the bar's middle is a hole in the page")
        #expect(!shape.contains(CGPoint(x: 101, y: 540)), "the bar's straight left edge is a hole")
        #expect(shape.contains(CGPoint(x: 101, y: 501)), "the page shows in the bar's bottom-left corner, outside its rounding")
        #expect(shape.contains(CGPoint(x: 699, y: 579)), "the page shows in the bar's top-right corner, outside its rounding")
        #expect(shape.contains(CGPoint(x: 400, y: 300)), "the page shows away from the bar")
    }

    @Test func aRoundedHoleChangesTheHostGeometry() {
        let host = CEFHostView(frame: Self.page)
        let before = CEFHostGeometry(of: host)
        host.roundedOcclusions = [Self.bar]
        let after = CEFHostGeometry(of: host)
        #expect(before != after, "the fork re-reads the clip when a bar appears")
        #expect(after.clip.path != nil)
    }

    @Test func aBarOutsideThePageAddsNoShape() {
        let away = CEFClipShape.RoundedRect(rect: CGRect(x: 900, y: 0, width: 50, height: 50), radius: 8)
        #expect(CEFClipShape.path(bounds: Self.page, clips: [], roundedHoles: [away]) == nil)
    }
}
