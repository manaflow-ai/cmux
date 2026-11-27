import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextAgentPane

/// Leo 2026-10-19: at a cold launch or after an update, the New Tab pane first painted the solid
/// theme color and only then the background image the sidebar already showed. The pane's first
/// frame is the page's saved image (`AgentPaneLaunchImages`), and that image was flattened over
/// the theme color although the New Tab page is transparent. A transparent page's image keeps
/// its clear pixels, so the window's art shows through it in the first frame.
@MainActor
struct PageImageBackgroundTests {
    /// A 4x4 page: clear but for its top-left pixel.
    private static func page() throws -> NSImage {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 3, width: 1, height: 1))
        return NSImage(cgImage: try #require(context.makeImage()), size: NSSize(width: 4, height: 4))
    }

    private static func alpha(_ image: NSImage, x: Int, y: Int) throws -> CGFloat {
        let rep = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        return try #require(rep.colorAt(x: x, y: y)).alphaComponent
    }

    @Test func theNewTabPageIsNeverBackedByAnOpaqueThemeColor() {
        let tokens = ThemeTokens.unresolved
        #expect(AgentPaneTheme.underPageColor(tokens, surface: .newTabPage).alpha < 1)
        #expect(AgentPaneTheme.pageColor(tokens, surface: .newTabPage).alpha < 1)
    }

    @Test func aTransparentPageImageKeepsItsClearPixels() throws {
        let color = AgentPaneTheme.underPageColor(ThemeTokens.unresolved, surface: .newTabPage)
        let image = PageImageBackground.fill(try Self.page(), color)
        #expect(try Self.alpha(image, x: 2, y: 2) == 0)
        #expect(try Self.alpha(image, x: 0, y: 0) == 1)
    }

    @Test func anOpaquePageImageIsFlattenedOverItsColor() throws {
        let color = AgentPaneTheme.underPageColor(ThemeTokens.unresolved, surface: .newTabPage).withAlpha(1)
        let image = PageImageBackground.fill(try Self.page(), color)
        #expect(try Self.alpha(image, x: 2, y: 2) == 1)
    }

    /// Leo 2026-10-26: "on restarting after an update/maybe in general, we dont wanna see a black
    /// background on the agent chat". A Chromium picture has no alpha, so a see-through page's clear
    /// pixels come out black; over a transparent window that picture was the relaunch's first frame.
    @Test func aPictureWithNoAlphaIsNoCoverForATransparentPage() throws {
        let clear = AgentPaneTheme.underPageColor(ThemeTokens.unresolved, surface: .newTabPage)
        #expect(clear.alpha < 1)
        #expect(PageImageBackground.cover(try Self.page(), color: clear, pageIsOpaque: false, keepsClearAreas: false) == nil)
    }

    @Test func aPictureWithNoAlphaStillCoversAnOpaquePage() throws {
        let opaque = AgentPaneTheme.underPageColor(ThemeTokens.unresolved, surface: .newTabPage).withAlpha(1)
        let image = try #require(PageImageBackground.cover(try Self.page(), color: opaque, pageIsOpaque: true, keepsClearAreas: false))
        #expect(try Self.alpha(image, x: 2, y: 2) == 1)
    }

    /// A surface background (`appearance.surfaces`) leaves the pane's under-page color clear, while
    /// the page itself paints opaque: its picture has no clear pixels to lose, so it still covers.
    @Test func aPictureWithNoAlphaCoversAPageWithItsOwnOpaqueBackground() throws {
        let clearUnder = AgentPaneTheme.underPageColor(ThemeTokens.unresolved, surface: .newTabPage)
        #expect(PageImageBackground.cover(try Self.page(), color: clearUnder, pageIsOpaque: true, keepsClearAreas: false) != nil)
    }

    /// The page background the host reads is the one the page paints (`WebTheme`): a New Tab page
    /// with no surface background of its own is clear in every window.
    @Test func theNewTabPagePaintsNoOpaqueBackgroundOfItsOwn() {
        #expect(AgentPaneTheme.pageBackground(ThemeTokens.unresolved, surface: .newTabPage).alpha < 1)
    }

    @Test func aPictureThatKeepsClearPixelsCoversATransparentPage() throws {
        let clear = AgentPaneTheme.underPageColor(ThemeTokens.unresolved, surface: .newTabPage)
        let image = try #require(PageImageBackground.cover(try Self.page(), color: clear, pageIsOpaque: false, keepsClearAreas: true))
        #expect(try Self.alpha(image, x: 2, y: 2) == 0)
    }

    @Test func noPictureIsNoCover() {
        #expect(PageImageBackground.cover(nil, color: ThemeTokens.unresolved.surfaceBackground.withAlpha(1), pageIsOpaque: true,
                                          keepsClearAreas: true) == nil)
    }

    /// A picture an older version saved (`AgentPaneLaunchImages`) gets the same rule when it is drawn:
    /// one with no alpha only over a page that paints opaque; one that keeps clear pixels always.
    @Test func aSavedPictureWithNoAlphaIsDrawnOnlyOverAnOpaquePage() throws {
        let flat = PageImageBackground.fill(try Self.page(), ThemeTokens.unresolved.surfaceBackground.withAlpha(1))
        #expect(!PageImageBackground.covers(flat, pageIsOpaque: false))
        #expect(PageImageBackground.covers(flat, pageIsOpaque: true))
        #expect(PageImageBackground.covers(try Self.page(), pageIsOpaque: false))
    }
}
