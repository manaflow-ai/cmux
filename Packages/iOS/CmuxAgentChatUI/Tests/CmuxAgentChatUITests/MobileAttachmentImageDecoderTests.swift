#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CmuxAgentChatUI

@Suite("Mobile attachment image decoder")
struct MobileAttachmentImageDecoderTests {
    @Test("full preview applies EXIF orientation and bounds decoded pixels")
    func appliesOrientationWithinPreviewBoundWithoutChangingBytes() throws {
        let stagedBytes = try orientedJPEG(width: 6_000, height: 3_000)
        let originalBytes = stagedBytes
        let decoder = MobileAttachmentImageDecoder()

        let decoded = try #require(decoder.decode(
            data: stagedBytes,
            maxPixelSize: MobileAttachmentImageDecoder.fullPreviewMaxPixelSize
        ))

        #expect(decoded.width == 2_048)
        #expect(decoded.height == 4_096)
        #expect(stagedBytes == originalBytes)
    }

    private func orientedJPEG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.82,
                kCGImagePropertyOrientation: 6,
            ] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
#endif
