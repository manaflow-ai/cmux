import AppKit
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``AppKit/NSColor/hexString(includeAlpha:)``: round-trips known
/// sRGB component values to their `#RRGGBB` / `#RRGGBBAA` encoding.
@Suite struct NSColorHexStringTests {
    @Test func opaquePrimaryEncodesAsUppercaseRGB() {
        let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(red.hexString() == "#FF0000")
    }

    @Test func midGrayRoundsComponentsToBytes() {
        let gray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        // 0.5 * 255 = 127.5 -> Int truncates to 127 -> 0x7F
        #expect(gray.hexString() == "#7F7F7F")
    }

    @Test func includeAlphaAppendsAlphaByte() {
        let translucent = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 0.5)
        #expect(translucent.hexString(includeAlpha: true) == "#0000FF7F")
    }

    @Test func alphaIsOmittedByDefault() {
        let translucent = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 0.25)
        #expect(translucent.hexString() == "#00FF00")
    }
}
