#if os(iOS)
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import CmuxMobileTerminal

@MainActor @Suite struct ImageCompressorTests {
    private func largeTIFF() throws -> Data {
        let size = CGSize(width: 2400, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setFillColor(UIColor.blue.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
        }
        let pixels = try #require(image.cgImage)
        let data = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil))
        let options = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]]
        CGImageDestinationAddImage(writer, pixels, options as CFDictionary)
        try #require(CGImageDestinationFinalize(writer))
        return data as Data
    }

    @Test func imageIsDownscaledToASmallerJPEG() async throws {
        let input = try largeTIFF()
        let result = await ImageCompressor.prepare(.data(input))
        let output = try #require(result)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: output)
        #expect(bytes.count < input.count)
        let jpeg = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        #expect(CGImageSourceGetType(jpeg) as String? == UTType.jpeg.identifier)
        let pixels = try #require(CGImageSourceCreateImageAtIndex(jpeg, 0, nil))
        #expect(pixels.width == 2048)
    }

    @Test func aNonSmallerImageRemovesOnlyItsAttemptFolder() throws {
        let data = try largeTIFF()
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel")
        try Data([1]).write(to: sentinel)

        let output = ImageCompressor.encode(image, bytes: 1, outputRoot: root)
        #expect(output == nil)
        let files = try manager.contentsOfDirectory(atPath: root.path)
        #expect(files == ["sentinel"])
        #expect(!AttachmentEncoding.isSmaller(sentinel, than: 1))
    }

    @Test func cancelledUploadDoesNotProduceJPEG() async throws {
        let data = try largeTIFF()
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ImageCompressor.prepare(.data(data))
        }.value
        #expect(result == nil)
    }
}
#endif
