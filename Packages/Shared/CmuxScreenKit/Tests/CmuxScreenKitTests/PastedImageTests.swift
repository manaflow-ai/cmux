@testable import CmuxScreenKitUI
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A picked photo becomes PNG or JPEG for the Mac's pasteboard at its full size, upright in its
/// pixels (an agent that reads the pixels sees it the right way up) and with no location in it:
/// not in GPS, IPTC or XMP.
struct PastedImageTests {
    /// Where a test photo says it was taken.
    enum Location: Sendable, CaseIterable { case gps, iptc, xmp }

    /// A corner of an image as it is shown.
    enum Corner: Sendable, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    /// A `width` x `height` image encoded as `type`: its stored top-left quarter red, the rest
    /// blue (a transparent corner at the bottom right with `alpha`), with `orientation` (EXIF) and
    /// `location` in its metadata.
    static func photo(_ type: UTType, width: Int = 64, height: Int = 48, alpha: Bool, orientation: Int = 1,
                      location: Location? = nil) throws -> Data {
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
        switch location {
        case .gps?:
            properties[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
                                                         kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"]
        case .iptc?:
            properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCity: "San Francisco",
                                                          kCGImagePropertyIPTCCountryPrimaryLocationName: "United States"]
        case .xmp?, nil:
            break
        }
        if location == .xmp {
            let metadata = CGImageMetadataCreateMutable()
            #expect(CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:City" as CFString, "San Francisco" as CFString))
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// What ImageIO reads of a photo: its type, size, orientation, any location it names, and its
    /// pixels (RGBA, rows from the top).
    struct Read {
        var type: String, width: Int, height: Int, orientation: Int
        /// The location fields found: `GPS`, `IPTC`, or an XMP path.
        var location: [String]
        var pixels: [UInt8]

        /// Whether `corner` is red (inset two pixels from the edges).
        func isRed(_ corner: Corner) -> Bool {
            let x = corner == .topLeft || corner == .bottomLeft ? 2 : width - 3
            let y = corner == .topLeft || corner == .topRight ? 2 : height - 3
            let at = (y * width + x) * 4
            return pixels[at] > 200 && pixels[at + 2] < 60
        }
    }

    static func read(_ data: Data) throws -> Read {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        var location: [String] = []
        if properties[kCGImagePropertyGPSDictionary] != nil { location.append("GPS") }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName].contains(where: { iptc[$0] != nil }) { location.append("IPTC") }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            for path in ["photoshop:City", "photoshop:Country", "Iptc4xmpCore:Location", "exif:GPSLatitude", "exif:GPSLongitude"]
            where CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) != nil { location.append(path) }
        }
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return Read(type: CGImageSourceGetType(source) as String? ?? "", width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                    height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
                    orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1, location: location, pixels: pixels)
    }

    @Test func uprightPngAndJpegWithNoLocationPassThroughUnchanged() throws {
        for (type, alpha) in [(UTType.png, true), (UTType.jpeg, false)] {
            let photo = try Self.photo(type, alpha: alpha)
            let pasted = try #require(PastedImage(photo: photo))
            #expect(pasted.type == type.identifier)
            #expect(pasted.data == photo, "\(type.identifier) is sent as it is")
        }
    }

    /// A photo's location, in GPS, IPTC or XMP, upright or not, never reaches the Mac (or an agent there).
    @Test(arguments: [(UTType.jpeg, Location.gps), (.jpeg, .iptc), (.jpeg, .xmp), (.png, .gps), (.png, .xmp),
                      (.tiff, .gps), (.tiff, .iptc), (.tiff, .xmp)])
    func aPhotoWithALocationIsSentWithoutIt(_ type: UTType, _ location: Location) throws {
        let photo = try Self.photo(type, alpha: type == .png, location: location)
        let before = try Self.read(photo)
        #expect(!before.location.isEmpty, "the test photo names a location")
        let pasted = try #require(PastedImage(photo: photo))
        #expect(try Self.read(pasted.data).location == [])
    }

    /// An upright JPEG or PNG with a location loses only the location: its pixels are the same
    /// (no second lossy encode).
    @Test(arguments: [(UTType.jpeg, Location.gps), (.jpeg, .iptc), (.png, .gps)])
    func anUprightPhotoWithALocationKeepsItsPixels(_ type: UTType, _ location: Location) throws {
        let photo = try Self.photo(type, width: 320, height: 240, alpha: false, location: location)
        let pasted = try #require(PastedImage(photo: photo))
        #expect(pasted.type == type.identifier)
        let before = try Self.read(photo), after = try Self.read(pasted.data)
        #expect((after.width, after.height) == (320, 240))
        #expect(after.pixels == before.pixels, "the same pixels")
    }

    /// A turned photo is sent with its pixels turned upright the right way: the stored top-left red
    /// quarter is where the orientation shows it (6: top right, 8: bottom left, 3: bottom right).
    @Test(arguments: [(6, Corner.topRight), (8, .bottomLeft), (3, .bottomRight)])
    func aTurnedPhotoIsSentUprightTheRightWay(_ orientation: Int, _ red: Corner) throws {
        // EXIF 5 to 8 turn the photo a quarter: its shown width is its stored height.
        let (width, height) = orientation >= 5 ? (480, 640) : (640, 480)
        for type in [UTType.jpeg, .tiff] {
            let photo = try Self.photo(type, width: 640, height: 480, alpha: false, orientation: orientation)
            let pasted = try #require(PastedImage(photo: photo))
            #expect(pasted.type == UTType.jpeg.identifier)
            let read = try Self.read(pasted.data)
            #expect((read.width, read.height) == (width, height), "\(type.identifier) \(orientation): turned, full size")
            #expect(read.orientation == 1, "no tag left to apply")
            for corner in Corner.allCases {
                #expect(read.isRed(corner) == (corner == red), "\(type.identifier) \(orientation): \(corner)")
            }
        }
    }

    @Test func anOpaquePhotoOfAnotherFormatBecomesAFullSizeJpeg() throws {
        let pasted = try #require(PastedImage(photo: try Self.photo(.tiff, width: 640, height: 480, alpha: false)))
        #expect(pasted.type == UTType.jpeg.identifier)
        let read = try Self.read(pasted.data)
        #expect(read.type == UTType.jpeg.identifier)
        #expect((read.width, read.height) == (640, 480), "full size, not scaled down")
        #expect(read.isRed(.topLeft) && !read.isRed(.bottomRight))
    }

    @Test func aPhotoWithTransparencyBecomesAPng() throws {
        let pasted = try #require(PastedImage(photo: try Self.photo(.tiff, alpha: true)))
        #expect(pasted.type == UTType.png.identifier)
        let read = try Self.read(pasted.data)
        #expect(read.type == UTType.png.identifier)
        #expect((read.width, read.height) == (64, 48))
    }

    /// Whether this machine's ImageIO can write HEIC, to make a test photo.
    static var writesHeic: Bool { (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(UTType.heic.identifier) }

    /// The iPhone's camera format, turned (orientation 8), with a location: an upright JPEG with
    /// none (skipped, and shown as skipped, where ImageIO cannot write HEIC).
    @Test(.enabled(if: PastedImageTests.writesHeic, "ImageIO here cannot write HEIC")) func aHeicPhotoBecomesAnUprightJpegWithNoLocation() throws {
        let photo = try Self.photo(.heic, width: 320, height: 240, alpha: false, orientation: 8, location: .gps)
        let pasted = try #require(PastedImage(photo: photo))
        #expect(pasted.type == UTType.jpeg.identifier)
        let read = try Self.read(pasted.data)
        #expect((read.width, read.height) == (240, 320))
        #expect(read.orientation == 1)
        #expect(read.isRed(.bottomLeft) && !read.isRed(.topRight), "turned 90° the right way")
        #expect(read.location == [])
    }

    /// A photo whose pixel size ImageIO cannot read is refused (the app says it could not be read),
    /// never sent as a 1-pixel image.
    @Test(arguments: [(nil, nil), (640, nil), (nil, 480), (0, 480), (640, 0)] as [(Int?, Int?)])
    func aPhotoWithNoPixelSizeIsRefused(_ width: Int?, _ height: Int?) throws {
        for (type, orientation) in [(UTType.tiff, 6), (.jpeg, 1)] {
            let photo = try Self.photo(type, width: 640, height: 480, alpha: false, orientation: orientation, location: .gps)
            let source = try #require(CGImageSourceCreateWithData(photo as CFData, nil))
            var properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            properties[kCGImagePropertyPixelWidth] = width
            properties[kCGImagePropertyPixelHeight] = height
            #expect(PastedImage(photo: photo, source: source, properties: properties) == nil,
                    "\(type.identifier) \(orientation), size \(String(describing: width)) x \(String(describing: height))")
        }
    }

    @Test func dataThatIsNoImageIsRefused() {
        #expect(PastedImage(photo: Data("not a photo".utf8)) == nil)
        #expect(PastedImage(photo: Data()) == nil)
    }
}
