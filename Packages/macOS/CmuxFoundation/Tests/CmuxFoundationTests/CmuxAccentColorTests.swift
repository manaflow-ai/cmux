import AppKit
import Testing

@testable import CmuxFoundation

@Suite struct CmuxAccentColorTests {
    @Test func lightAndDarkUseTheCmuxBlues() {
        #expect(rgbBytes(CmuxAccentColor.nsColor(isDark: false)) == [0, 136, 255])
        #expect(rgbBytes(CmuxAccentColor.nsColor(isDark: true)) == [0, 145, 255])
    }

    @Test func appearanceResolvesToMatchingScheme() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        #expect(rgbBytes(CmuxAccentColor.nsColor(for: dark)) == [0, 145, 255])
        #expect(rgbBytes(CmuxAccentColor.nsColor(for: aqua)) == [0, 136, 255])
        #expect(rgbBytes(CmuxAccentColor.nsColor(for: nil)) == [0, 136, 255])
    }

    @Test func dynamicColorFollowsDrawingAppearance() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        var darkBytes: [Int] = []
        var lightBytes: [Int] = []
        dark.performAsCurrentDrawingAppearance {
            darkBytes = rgbBytes(CmuxAccentColor.dynamicNSColor)
        }
        aqua.performAsCurrentDrawingAppearance {
            lightBytes = rgbBytes(CmuxAccentColor.dynamicNSColor)
        }
        #expect(darkBytes == [0, 145, 255])
        #expect(lightBytes == [0, 136, 255])
    }

    private func rgbBytes(_ color: NSColor) -> [Int] {
        guard let srgb = color.usingColorSpace(.sRGB) else { return [] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int(($0 * 255).rounded()) }
    }
}
