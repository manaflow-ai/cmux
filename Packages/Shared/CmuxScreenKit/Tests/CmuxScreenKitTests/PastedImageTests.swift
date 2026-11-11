@testable import CmuxScreenKitUI
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A picked photo becomes PNG or JPEG for the Mac's pasteboard at its full size, through ImageIO.
struct PastedImageTests {
    /// A `width` x `height` image, opaque or with a transparent corner, encoded as `type`, with
    /// `orientation` (EXIF) in its metadata.
    static func photo(_ type: UTType, width: Int = 64, height: Int = 48, alpha: Bool, orientation: Int = 1) throws -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: info))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if alpha { context.clear(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The type, pixel size and orientation of `data` as ImageIO reads it.
    static func read(_ data: Data) throws -> (type: String, width: Int, height: Int, orientation: Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (CGImageSourceGetType(source) as String? ?? "",
                properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
                properties[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    @Test func pngAndJpegPassThroughUnchanged() throws {
        for (type, alpha) in [(UTType.png, true), (UTType.jpeg, false)] {
            let photo = try Self.photo(type, alpha: alpha)
            let pasted = try #require(PastedImage(photo: photo))
            #expect(pasted.type == type.identifier)
            #expect(pasted.data == photo, "\(type.identifier) is sent as it is")
        }
    }

    @Test func anOpaquePhotoOfAnotherFormatBecomesAFullSizeJpegThatKeepsItsOrientation() throws {
        let pasted = try #require(PastedImage(photo: try Self.photo(.tiff, width: 640, height: 480, alpha: false, orientation: 6)))
        #expect(pasted.type == UTType.jpeg.identifier)
        let read = try Self.read(pasted.data)
        #expect(read.type == UTType.jpeg.identifier)
        #expect(read.width == 640 && read.height == 480, "full size, not scaled down")
        #expect(read.orientation == 6, "the photo is not shown on its side on the Mac")
    }

    @Test func aPhotoWithTransparencyBecomesAPng() throws {
        let pasted = try #require(PastedImage(photo: try Self.photo(.tiff, alpha: true)))
        #expect(pasted.type == UTType.png.identifier)
        let read = try Self.read(pasted.data)
        #expect(read.type == UTType.png.identifier)
        #expect(read.width == 64 && read.height == 48)
    }

    /// Whether this machine's ImageIO can write HEIC, to make a test photo.
    static let writesHeic = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier)

    /// The iPhone's camera format (skipped, and shown as skipped, where ImageIO cannot write it).
    @Test(.enabled(if: PastedImageTests.writesHeic, "ImageIO here cannot write HEIC")) func aHeicPhotoBecomesAJpeg() throws {
        let pasted = try #require(PastedImage(photo: try Self.photo(.heic, width: 320, height: 240, alpha: false, orientation: 3)))
        #expect(pasted.type == UTType.jpeg.identifier)
        let read = try Self.read(pasted.data)
        #expect(read.width == 320 && read.height == 240)
        #expect(read.orientation == 3)
    }

    @Test func dataThatIsNoImageIsRefused() {
        #expect(PastedImage(photo: Data("not a photo".utf8)) == nil)
        #expect(PastedImage(photo: Data()) == nil)
    }
}
