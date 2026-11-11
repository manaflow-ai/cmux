@testable import CmuxScreenKitUI
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A picked photo becomes PNG or JPEG for the Mac's pasteboard at its full size, through ImageIO,
/// upright in its pixels (an agent that reads the pixels sees it the right way up) and with no
/// location in it.
struct PastedImageTests {
    /// Where a test photo was taken: GPS metadata the sent image must not carry.
    static var gps: [CFString: Any] {
        [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
         kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"]
    }

    /// A `width` x `height` image encoded as `type`: its stored top-left quarter red, the rest
    /// blue (a transparent corner at the bottom right with `alpha`), with `orientation` (EXIF) and,
    /// with `located`, ``gps`` in its metadata.
    static func photo(_ type: UTType, width: Int = 64, height: Int = 48, alpha: Bool, orientation: Int = 1,
                      located: Bool = false) throws -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: info))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CoreGraphics' origin is the bottom left: the stored image's top-left quarter is high y.
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2))
        if alpha { context.clear(CGRect(x: width - 8, y: 0, width: 8, height: 8)) }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if located { properties[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// What ImageIO reads of `data`: its type, pixel size, orientation, whether it has GPS, and
    /// whether its top-left pixel (as stored) is red.
    static func read(_ data: Data) throws -> (type: String, width: Int, height: Int, orientation: Int, located: Bool, redTopLeft: Bool) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixel.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Only the stored top-left pixel lands in the 1x1 context.
            context.draw(image, in: CGRect(x: 0, y: 1 - image.height, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return (CGImageSourceGetType(source) as String? ?? "",
                properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
                properties[kCGImagePropertyOrientation] as? Int ?? 1,
                properties[kCGImagePropertyGPSDictionary] != nil,
                pixel[0] > 200 && pixel[2] < 60)
    }

    @Test func uprightPngAndJpegWithNoLocationPassThroughUnchanged() throws {
        for (type, alpha) in [(UTType.png, true), (UTType.jpeg, false)] {
            let photo = try Self.photo(type, alpha: alpha)
            let pasted = try #require(PastedImage(photo: photo))
            #expect(pasted.type == type.identifier)
            #expect(pasted.data == photo, "\(type.identifier) is sent as it is")
        }
    }

    /// A camera JPEG says where it was taken: the Mac (and any agent there) never gets that.
    @Test func aPhotoWithALocationIsSentWithout() throws {
        for (type, alpha) in [(UTType.jpeg, false), (UTType.tiff, false), (UTType.png, true)] {
            let photo = try Self.photo(type, alpha: alpha, located: true)
            #expect(try Self.read(photo).located, "the test photo of \(type.identifier) has a location")
            let pasted = try #require(PastedImage(photo: photo))
            #expect(!(try Self.read(pasted.data).located), "\(type.identifier): the location is gone")
        }
    }

    /// A photo taken sideways (EXIF orientation 6) is sent with its pixels turned upright: an agent
    /// that reads pixels and not the tag sees it the right way up.
    @Test func aSidewaysPhotoIsSentUprightInItsPixels() throws {
        for type in [UTType.jpeg, .tiff] {
            let pasted = try #require(PastedImage(photo: try Self.photo(type, width: 640, height: 480, alpha: false, orientation: 6)))
            #expect(pasted.type == UTType.jpeg.identifier)
            let read = try Self.read(pasted.data)
            #expect(read.width == 480 && read.height == 640, "\(type.identifier): turned, full size: \(read)")
            #expect(read.orientation == 1, "no tag left to apply")
            // Orientation 6 shows the stored image turned 90° clockwise: its top-left red quarter lands top right.
            #expect(!read.redTopLeft)
        }
    }

    @Test func anOpaquePhotoOfAnotherFormatBecomesAFullSizeJpeg() throws {
        let pasted = try #require(PastedImage(photo: try Self.photo(.tiff, width: 640, height: 480, alpha: false)))
        #expect(pasted.type == UTType.jpeg.identifier)
        let read = try Self.read(pasted.data)
        #expect(read.type == UTType.jpeg.identifier)
        #expect(read.width == 640 && read.height == 480, "full size, not scaled down")
        #expect(read.redTopLeft)
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

    /// The iPhone's camera format, upside down (orientation 3), with a location: an upright JPEG with
    /// none (skipped, and shown as skipped, where ImageIO cannot write HEIC).
    @Test(.enabled(if: PastedImageTests.writesHeic, "ImageIO here cannot write HEIC")) func aHeicPhotoBecomesAnUprightJpegWithNoLocation() throws {
        let photo = try Self.photo(.heic, width: 320, height: 240, alpha: false, orientation: 3, located: true)
        let pasted = try #require(PastedImage(photo: photo))
        #expect(pasted.type == UTType.jpeg.identifier)
        let read = try Self.read(pasted.data)
        #expect(read.width == 320 && read.height == 240)
        #expect(read.orientation == 1)
        #expect(!read.redTopLeft, "turned 180°: the red quarter is at the bottom right")
        #expect(!read.located)
    }

    @Test func dataThatIsNoImageIsRefused() {
        #expect(PastedImage(photo: Data("not a photo".utf8)) == nil)
        #expect(PastedImage(photo: Data()) == nil)
    }
}
