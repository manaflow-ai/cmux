#if os(iOS)
import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import CmuxMobileTerminal

@MainActor @Suite struct ImageCompressorPreservationTests {
    private func encodedImage(type: UTType, frames: Int, alpha: Bool = false) throws -> Data {
        let size = CGSize(width: 2400, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !alpha
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil))
        for frame in 0..<frames {
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                // Leave half the transparent fixture untouched, then verify those
                // pixels survive the actual encoded output, not just its metadata.
                context.cgContext.setFillColor((frame == 0 ? UIColor.blue : UIColor.red).cgColor)
                let width = alpha ? size.width / 2 : size.width
                context.cgContext.fill(CGRect(x: 0, y: 0, width: width, height: size.height))
            }
            let pixels = try #require(image.cgImage)
            let properties: [CFString: Any] = type == .tiff
                ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] : [:]
            CGImageDestinationAddImage(destination, pixels, properties as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test(arguments: [UTType.gif.identifier, UTType.tiff.identifier])
    func animationAndDocumentPagesKeepOriginalBytes(typeIdentifier: String) async throws {
        let type = try #require(UTType(typeIdentifier))
        let data = try encodedImage(type: type, frames: 2)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 2)
        // The first frame is oversized, so the old implementation would flatten it.
        #expect(ImageCompressor.plan(for: source, bytes: data.count)?.reencode == true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("picked.\(type.preferredFilenameExtension ?? "image")")
        try data.write(to: file)
        #expect(await ImageCompressor.prepare(.file(file)) == nil)
        #expect(try Data(contentsOf: file) == data)
        #expect(await ImageCompressor.prepare(.data(data)) == nil)
    }

    @Test func transparentImageRemainsTransparentAfterDownscaling() async throws {
        let data = try encodedImage(type: .tiff, frames: 1, alpha: true)
        let output = try #require(await ImageCompressor.prepare(.data(data)))
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent()) }
        let outputData = try Data(contentsOf: output)
        let source = try #require(CGImageSourceCreateWithData(outputData as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        #expect(output.pathExtension == "png")
        #expect(ImageCompressor.encodedName("scan.tiff", extension: output.pathExtension) == "scan.png")
        #expect(outputData.count < data.count)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2048)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
                                           bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let row = image.height / 2 * context.bytesPerRow
        #expect(pixels[row + image.width / 4 * 4 + 3] == 255)
        #expect(pixels[row + image.width * 3 / 4 * 4 + 3] == 0)
    }
}
#endif
