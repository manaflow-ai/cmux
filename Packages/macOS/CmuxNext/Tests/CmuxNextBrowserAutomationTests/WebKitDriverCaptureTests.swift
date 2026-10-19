import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CmuxNextBrowserAutomation

@Suite struct WebKitDriverCaptureTests {
    @Test(arguments: [(false, UTType.png.identifier), (true, UTType.jpeg.identifier)])
    func screenshotEncodingRunsOffMainAndDecodes(jpeg: Bool, type: String) async throws {
        let image = try #require(Self.image())
        let encoded = try #require(await WebKitDriver.encodeScreenshot(image, jpeg: jpeg, quality: 0.8))
        #expect(!encoded.ranOnMainThread)

        let data = try #require(Data(base64Encoded: encoded.base64))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == type)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == image.width)
        #expect(decoded.height == image.height)
    }

    private static func image() -> CGImage? {
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.15, green: 0.35, blue: 0.75, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 4, y: 5, width: 11, height: 7))
        return context.makeImage()
    }
}
