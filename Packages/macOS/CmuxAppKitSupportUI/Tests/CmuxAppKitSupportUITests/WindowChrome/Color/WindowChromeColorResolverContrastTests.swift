import AppKit
import Testing

@testable import CmuxAppKitSupportUI

@Suite struct WindowChromeColorResolverContrastTests {
    private let resolver = WindowChromeColorResolver()

    /// Hot Dog Stand's red backdrop took half-opacity black secondary text to
    /// about 2.6:1; the floor raises only the opacity until it reads.
    @Test func saturatedBackdropRaisesSecondaryOpacityToTheFloor() throws {
        let red = try #require(NSColor(hex: "#E44330"))
        let secondary = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)
        #expect(contrast(secondary, over: red) < 3.5)

        let floored = resolver.contrastFloored(secondary, over: red, minimumContrast: 3.5)

        #expect(contrast(floored, over: red) >= 3.5)
        #expect(floored.alphaComponent > secondary.alphaComponent)
        #expect(floored.alphaComponent < 1)
    }

    /// Neutral themes keep the system secondary color untouched.
    @Test func readableSecondaryIsReturnedUnchanged() throws {
        let white = try #require(NSColor(hex: "#FFFFFF"))
        let secondary = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.5)

        let floored = resolver.contrastFloored(secondary, over: white, minimumContrast: 3.5)

        #expect(floored.alphaComponent == secondary.alphaComponent)
    }

    /// When even the opaque color cannot reach the floor, the most readable
    /// version, fully opaque, is returned.
    @Test func unreachableFloorReturnsOpaqueColor() throws {
        let gray = try #require(NSColor(hex: "#777777"))
        let secondary = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)

        let floored = resolver.contrastFloored(secondary, over: gray, minimumContrast: 7)

        #expect(floored.alphaComponent == 1)
    }

    private func contrast(_ foreground: NSColor, over background: NSColor) -> CGFloat {
        resolver.contrastRatio(resolver.compositedColor(foreground, over: background), background)
    }
}
