@testable import CmuxMobileAgentChat
import Foundation
import Testing

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@Suite struct AgentImageOptimizerTests {
    @Test func shrinksLargeJPEGAndKeepsItAsAnAcceptedImage() throws {
        let image = try #require(makeImage(width: 3000, height: 2200, alpha: false))
        let original = try encode(image, type: UTType.jpeg.identifier as CFString, quality: 1)
        let optimized = AgentImageOptimizer.optimize(original)

        #expect(optimized.count < original.count)
        #expect(AgentAttachment(kind: .image, name: "photo", data: optimized).imageMIMEType == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(optimized as CFData, nil))
        let thumbnail = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(thumbnail.width, thumbnail.height) <= AgentImageOptimizer.maxPixelSize)
    }

    @Test func keepsTransparencyWhenOptimizingPNG() throws {
        let image = try #require(makeImage(width: 3000, height: 2200, alpha: true))
        let original = try encode(image, type: UTType.png.identifier as CFString)
        let optimized = AgentImageOptimizer.optimize(original)

        #expect(optimized.count < original.count)
        #expect(AgentAttachment(kind: .image, name: "transparent", data: optimized).imageMIMEType == "image/png")
    }

    private func makeImage(width: Int, height: Int, alpha: Bool) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(truncatingIfNeeded: x * 31 + y * 17)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: x * 13 + y * 29)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: x * 7 + y * 43)
                bytes[offset + 3] = alpha ? UInt8(truncatingIfNeeded: x + y) : 255
            }
        }
        return context.makeImage()
    }

    private func encode(_ image: CGImage, type: CFString, quality: CGFloat? = nil) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type, 1, nil))
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
#endif
