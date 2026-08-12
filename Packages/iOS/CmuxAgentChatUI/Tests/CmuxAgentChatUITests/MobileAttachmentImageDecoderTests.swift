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
        let source = try #require(CGImageSourceCreateWithData(stagedBytes as CFData, nil))
        let copiedProperties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil))
        let sourceProperties = copiedProperties as NSDictionary
        let tiffProperties = try #require(
            sourceProperties[kCGImagePropertyTIFFDictionary] as? NSDictionary
        )
        let sourceImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let expectedOrientation = Int(CGImagePropertyOrientation.right.rawValue)

        #expect((sourceProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 6_000)
        #expect((sourceProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 3_000)
        #expect((sourceProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == expectedOrientation)
        #expect(
            (tiffProperties[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue
                == expectedOrientation
        )
        #expect(sourceImage.width == 6_000)
        #expect(sourceImage.height == 3_000)

        let decoded = try #require(decoder.decode(
            data: stagedBytes,
            maxPixelSize: MobileAttachmentImageDecoder.fullPreviewMaxPixelSize
        ))

        #expect(decoded.width == 2_048)
        #expect(decoded.height == 4_096)
        let topLeft = try pixelRGBA(
            in: decoded,
            x: decoded.width / 4,
            y: decoded.height * 3 / 4
        )
        let bottomLeft = try pixelRGBA(
            in: decoded,
            x: decoded.width / 4,
            y: decoded.height / 4
        )
        #expect(topLeft.red > 200)
        #expect(topLeft.green > 150)
        #expect(topLeft.blue < 100)
        #expect(bottomLeft.red < 100)
        #expect(bottomLeft.green < 150)
        #expect(bottomLeft.blue > 150)
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
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
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
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFOrientation: CGImagePropertyOrientation.right.rawValue,
                ] as CFDictionary,
            ] as CFDictionary
        )
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixelRGBA(
        in image: CGImage,
        x: Int,
        y: Int
    ) throws -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.translateBy(x: -CGFloat(x), y: -CGFloat(y))
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
#endif
