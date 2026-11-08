import AppKit
import Testing

@testable import CmuxFoundation

@Suite struct NSColorColorSpaceSafetyTests {
    @Test func darkensCatalogColorAfterConvertingToSRGB() throws {
        let systemBlue = NSColor.systemBlue
        let source = try #require(systemBlue.usingColorSpace(.sRGB))

        let darkened = systemBlue.darken(by: 0.2)
        let result = try #require(darkened.usingColorSpace(.sRGB))

        #expect(result.greenComponent < source.greenComponent)
        #expect(result.blueComponent < source.blueComponent)
        #expect(result.alphaComponent == source.alphaComponent)
    }

    @Test func darkensGrayscaleColorAfterConvertingToSRGB() throws {
        let grayscale = NSColor(calibratedWhite: 0.8, alpha: 0.6)
        let source = try #require(grayscale.usingColorSpace(.sRGB))

        let darkened = grayscale.darken(by: 0.25)
        let result = try #require(darkened.usingColorSpace(.sRGB))

        #expect(result.redComponent < source.redComponent)
        #expect(abs(result.redComponent - result.greenComponent) < 0.0001)
        #expect(abs(result.greenComponent - result.blueComponent) < 0.0001)
        #expect(result.alphaComponent == source.alphaComponent)
    }

    @Test func preservesColorWhenRGBConversionIsUnavailable() {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let pattern = NSColor(patternImage: image)

        #expect(pattern.usingColorSpace(.sRGB) == nil)
        #expect(pattern.darken(by: 0.2) === pattern)
    }

    @Test func hexStringFallsBackForColorWithoutRGBConversion() {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let pattern = NSColor(patternImage: image)

        #expect(pattern.hexString() == "#000000")
        #expect(pattern.hexString(includeAlpha: true) == "#000000FF")
    }
}
