import CoreGraphics
@testable import CmuxNextDesign
import Testing

/// The glass sidebar experiment's look (`experiments.glassSidebarExtension`, taste build 2026-11-19): off changes
/// nothing, each variant floats or flushes the card and extends or not, and Reduce Transparency extends nothing.
struct GlassSidebarLookTests {
    @Test func offIsTheWindowAsBefore() {
        for variant in GlassSidebarVariant.allCases {
            #expect(GlassSidebarLook.resolve(on: false, variant: variant, inset: 6, reduceTransparency: false) == .off)
        }
        #expect(GlassSidebarLook.off.cardRadius(mainPane: 9, windowCornerRadius: 16) == 9)
    }

    @Test func extendedIsAnInsetCardOverTheExtendedPane() {
        let look = GlassSidebarLook.resolve(on: true, variant: .extended, inset: 6, reduceTransparency: false)
        #expect(look == GlassSidebarLook(glassSidebar: true, sidebarInset: 6, extendsContent: true, fullBleed: true))
        #expect(look.cardRadius(mainPane: 9, windowCornerRadius: 16) == 10)
    }

    @Test func glassOnlyExtendsNothingAndFlushHasNoInset() {
        #expect(!GlassSidebarLook.resolve(on: true, variant: .glassOnly, inset: 6, reduceTransparency: false).extendsContent)
        let flush = GlassSidebarLook.resolve(on: true, variant: .flush, inset: 6, reduceTransparency: false)
        #expect(flush.sidebarInset == 0 && flush.extendsContent && flush.fullBleed)
    }

    @Test func aStyleWithNoGutterStillInsetsTheCard() {
        #expect(GlassSidebarLook.resolve(on: true, variant: .extended, inset: 0, reduceTransparency: false).sidebarInset == 6)
    }

    @Test func reduceTransparencyExtendsNothing() {
        for variant in GlassSidebarVariant.allCases {
            #expect(!GlassSidebarLook.resolve(on: true, variant: variant, inset: 6, reduceTransparency: true).extendsContent)
        }
    }
}
