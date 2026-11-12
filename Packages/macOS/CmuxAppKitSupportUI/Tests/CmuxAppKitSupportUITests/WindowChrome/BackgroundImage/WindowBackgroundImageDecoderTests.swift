import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CmuxAppKitSupportUI

/// Covers decoding a real image file into a bounded bitmap.
@Suite struct WindowBackgroundImageDecoderTests {
    @Test func largeImageIsDownsampledKeepingItsAspectRatio() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wide.png")
        try writePNG(width: 400, height: 200, to: url)

        let image = try #require(WindowBackgroundImageDecoder(maxPixelSize: 100).decode(contentsOf: url))

        #expect(image.cgImage.width == 100)
        #expect(image.cgImage.height == 50)
    }

    @Test func smallImageIsNotEnlarged() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("small.png")
        try writePNG(width: 40, height: 30, to: url)

        let image = try #require(WindowBackgroundImageDecoder(maxPixelSize: 100).decode(contentsOf: url))

        #expect(image.cgImage.width == 40)
        #expect(image.cgImage.height == 30)
    }

    @Test func missingOrNonImageFilesDecodeToNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appendingPathComponent("notes.png")
        try Data("not an image".utf8).write(to: text)

        let decoder = WindowBackgroundImageDecoder()
        #expect(decoder.decode(contentsOf: text) == nil)
        #expect(decoder.decode(contentsOf: directory.appendingPathComponent("missing.png")) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowBackgroundImageDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
