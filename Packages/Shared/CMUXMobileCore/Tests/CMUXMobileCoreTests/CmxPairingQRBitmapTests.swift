import CoreGraphics
import Testing

@testable import CMUXMobileCore

@Suite struct CmxPairingQRBitmapTests {
    private let oneRoutePayload = "cmux-ios://attach?v=2&tr=ticket-ref-123&r=100.64.0.5:52341"
    private let twoRoutePayload =
        "cmux-ios://attach?v=2&tr=ticket-ref-123&r=lawrences-mac.tail1234.ts.net:52341&r=100.64.0.5:52341"

    /// The full 4-module quiet zone is part of the bitmap itself, so it
    /// scales with the code and cannot be cropped away by view layout. Also
    /// pins the assumption that the Core Image generator's own margin is
    /// exactly 1 module: were it wider or narrower, the module arithmetic
    /// in `moduleCount(of:)` would stop matching a legal QR version and
    /// `moduleCountMatchesAVersionAtOrBelowSix` would fail.
    @Test func bakesFullQuietZoneIntoBitmap() throws {
        let image = try #require(CmxPairingQRBitmap().makeImage(payload: oneRoutePayload))
        #expect(image.width == image.height)

        let pixels = try grayLevels(of: image)
        let quiet = CmxPairingQRBitmap.quietZoneModules
        #expect(image.width > quiet * 2)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let inQuietZone =
                    x < quiet || y < quiet
                    || x >= image.width - quiet || y >= image.height - quiet
                if inQuietZone {
                    #expect(
                        pixels[y * image.width + x] > 245,
                        "expected white quiet zone at (\(x), \(y))"
                    )
                }
            }
        }
    }

    /// Every pixel is pure black or pure white: full scanning contrast,
    /// independent of app theme, and no interpolation gray (the bitmap is
    /// generated at module resolution, never resampled).
    @Test func rendersPureBlackOnPureWhiteOnly() throws {
        let image = try #require(CmxPairingQRBitmap().makeImage(payload: oneRoutePayload))
        let pixels = try grayLevels(of: image)
        #expect(pixels.contains { $0 < 10 }, "expected black modules")
        #expect(pixels.contains { $0 > 245 }, "expected white background")
        let grayCount = pixels.count { $0 >= 10 && $0 <= 245 }
        #expect(grayCount == 0, "expected no mid-gray pixels, found \(grayCount)")
    }

    /// At ECC M the representative pairing payloads stay at QR version 6 or
    /// lower (41 modules), so each module still renders large in the pairing
    /// window. Version v has 17 + 4v modules per side; a side count that
    /// breaks that arithmetic means the margin assumption in the renderer is
    /// wrong.
    @Test func moduleCountMatchesAVersionAtOrBelowSix() throws {
        for payload in [oneRoutePayload, twoRoutePayload] {
            let image = try #require(CmxPairingQRBitmap().makeImage(payload: payload))
            let modules = image.width - CmxPairingQRBitmap.quietZoneModules * 2
            #expect((modules - 17) % 4 == 0, "\(modules) modules is not a QR version")
            #expect(modules >= 21)
            #expect(modules <= 41, "payload should stay at version <= 6, got \(modules) modules")
        }
    }

    /// Renders `image` into an sRGB bitmap and reduces each pixel to its red
    /// channel; the QR is grayscale, so one channel carries the module value.
    private func grayLevels(of image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
            )
        }
        return stride(from: 0, to: rgba.count, by: 4).map { rgba[$0] }
    }
}
