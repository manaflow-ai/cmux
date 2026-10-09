import AppKit
import Testing
@testable import MessagesLabSidebar

/// Crash program: the sidebar's fonts, color space and palette no longer force-unwrap.
/// These pin that the literals resolve, so the fallbacks never run.
@MainActor @Suite struct SidebarCrashSafeTests {
    @Test func fontsAndColorSpaceResolve() {
        #expect(CTFontCreateUIFontForLanguage(.emphasizedSystem, 13, nil) != nil)
        #expect(CTFontGetSize(sidebarUIFont(.system, 12)) == 12)
        #expect(SidebarDraw.p3.name == CGColorSpace.displayP3)
    }

    @Test func paletteResolvesInBothAppearances() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let light = try #require(NSAppearance(named: .aqua))
        #expect(SidebarPalette.resolve(dark).dark)
        #expect(!SidebarPalette.resolve(light).dark)
        #expect(SidebarPalette.resolve(dark).monogramTop.colorSpace?.name == CGColorSpace.displayP3)
    }
}
