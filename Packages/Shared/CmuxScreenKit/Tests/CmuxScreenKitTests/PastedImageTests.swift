@testable import CmuxScreenKitUI
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A picked photo becomes PNG or JPEG for the Mac's pasteboard at its full size, upright in its
/// pixels (an agent that reads the pixels sees it the right way up) and with no metadata in it:
/// no EXIF, GPS, IPTC, XMP or maker note, whatever its tags are named.
struct PastedImageTests {
    /// Metadata a test photo carries: where it was taken (GPS, IPTC, a known XMP tag, an XMP tag
    /// in a namespace of its own that no list of place names knows), or camera data in EXIF.
    enum Location: Sendable, CaseIterable { case gps, iptc, xmp, customXMP, camera }

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
        case .camera?:
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone",
                                                          kCGImagePropertyTIFFOrientation: orientation]
            // A camera's own pixel size and color space, unlike this image's: never sent.
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: "2026:11:11 12:00:00",
                                                          kCGImagePropertyExifUserComment: "at home",
                                                          kCGImagePropertyExifPixelXDimension: 4032,
                                                          kCGImagePropertyExifPixelYDimension: 3024,
                                                          kCGImagePropertyExifColorSpace: 2]
        case .xmp?, .customXMP?, nil:
            break
        }
        if location == .xmp || location == .customXMP {
            let metadata = CGImageMetadataCreateMutable()
            if location == .xmp {
                #expect(CGImageMetadataSetValueWithPath(metadata, nil, "photoshop:City" as CFString, "San Francisco" as CFString))
            } else {
                #expect(CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.example.com/spot/1.0/" as CFString,
                                                                  "spot" as CFString, nil))
                #expect(CGImageMetadataSetValueWithPath(metadata, nil, "spot:Place" as CFString, "Golden Gate Park" as CFString))
            }
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// What ImageIO reads of a photo: its type, size, orientation, any metadata, and its pixels
    /// (RGBA, rows from the top).
    struct Read {
        var type: String, width: Int, height: Int, orientation: Int
        /// Every metadata field found that does not only describe the pixels (`{Exif}`,
        /// `{TIFF}.Make`, an XMP tag `prefix:name`, …): empty for a photo that carries none.
        var metadata: [String]
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
        let metadata = Self.metadata(source, properties: properties)
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
                    orientation: properties[kCGImagePropertyOrientation] as? Int ?? 1, metadata: metadata, pixels: pixels)
    }

    /// What describes only the pixels, by dictionary: the rest is metadata. Written apart from the
    /// code under test, so the test does not take that code's word for what is safe.
    static var pixelOnly: [String: Set<String>] {
        [
            "{JFIF}": Set([kCGImagePropertyJFIFVersion, kCGImagePropertyJFIFXDensity, kCGImagePropertyJFIFYDensity,
                           kCGImagePropertyJFIFDensityUnit, kCGImagePropertyJFIFIsProgressive].map { $0 as String }),
            "{PNG}": Set([kCGImagePropertyPNGGamma, kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGsRGBIntent,
                          kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter,
                          kCGImagePropertyPNGCompressionFilter].map { $0 as String }),
            "{TIFF}": Set([kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                           kCGImagePropertyTIFFResolutionUnit].map { $0 as String }),
            // ImageIO's PNG and JPEG encoders write these on their own, for any image.
            "{Exif}": Set([kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension,
                           kCGImagePropertyExifPixelYDimension].map { $0 as String }),
        ]
    }

    /// The values the allowed `{Exif}` keys may have: the encoder's own, so the pixel size of the
    /// image as written and sRGB (the test photos' color space). A value from the source that
    /// differs is metadata.
    static func encoderValues(_ properties: [CFString: Any]) -> [String: String] {
        [
            kCGImagePropertyExifPixelXDimension as String: "\(properties[kCGImagePropertyPixelWidth] as? Int ?? -1)",
            kCGImagePropertyExifPixelYDimension as String: "\(properties[kCGImagePropertyPixelHeight] as? Int ?? -1)",
            kCGImagePropertyExifColorSpace as String: "1",
        ]
    }

    /// Every metadata field of the first image of `source` (see ``Read/metadata``).
    static func metadata(_ source: CGImageSource, properties: [CFString: Any]) -> [String] {
        var found: [String] = []
        let expected = encoderValues(properties)
        if let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any] {
            found += exif.compactMap { key, value in
                guard let wanted = expected[key], "\(value)" != wanted else { return nil }
                return "{Exif}.\(key)=\(value)"
            }
        }
        for (key, value) in properties {
            guard let dictionary = value as? [String: Any] else { continue }
            guard let allowed = pixelOnly[key as String] else {
                found.append(key as String)
                continue
            }
            found += dictionary.keys.filter { !allowed.contains($0) }.map { "\(key).\($0)" }
        }
        if let tags = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap({ CGImageMetadataCopyTags($0) as? [CGImageMetadataTag] }) {
            for tag in tags {
                let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? "?"
                let name = CGImageMetadataTagCopyName(tag) as String? ?? "?"
                // An XMP tag's prefix names the dictionary it mirrors.
                let mirrors = ["tiff": "{TIFF}", "exif": "{Exif}"][prefix].flatMap { pixelOnly[$0] } ?? []
                if !mirrors.contains(name) {
                    found.append("\(prefix):\(name)")
                } else if prefix == "exif", let wanted = expected[name],
                          let value = CGImageMetadataTagCopyValue(tag), "\(value)" != wanted {
                    found.append("\(prefix):\(name)=\(value)")
                }
            }
        }
        return found.sorted()
    }

    /// Any metadata a photo has, upright or not, whatever its tags are named, never reaches the Mac
    /// (or an agent there): no EXIF, GPS, IPTC, XMP or maker note is left.
    @Test(arguments: [(UTType.jpeg, Location.gps), (.jpeg, .iptc), (.jpeg, .xmp), (.jpeg, .customXMP), (.jpeg, .camera),
                      (.png, .gps), (.png, .xmp), (.png, .customXMP),
                      (.tiff, .gps), (.tiff, .iptc), (.tiff, .xmp), (.tiff, .customXMP), (.tiff, .camera)])
    func aPhotoIsSentWithNoMetadata(_ type: UTType, _ location: Location) throws {
        let photo = try Self.photo(type, alpha: type == .png, location: location)
        #expect(!(try Self.read(photo).metadata.isEmpty), "the test photo has metadata")
        let pasted = try #require(PastedImage(photo: photo))
        #expect(try Self.read(pasted.data).metadata == [])
    }

    /// An upright JPEG or PNG keeps its type and its pixels (no second lossy encode), with or
    /// without metadata to drop.
    @Test(arguments: [(UTType.jpeg, nil), (.png, nil), (.jpeg, .gps), (.jpeg, .iptc), (.jpeg, .customXMP), (.jpeg, .camera),
                      (.png, .gps), (.png, .customXMP)] as [(UTType, Location?)])
    func anUprightPhotoKeepsItsTypeAndPixels(_ type: UTType, _ location: Location?) throws {
        let photo = try Self.photo(type, width: 320, height: 240, alpha: false, location: location)
        let pasted = try #require(PastedImage(photo: photo))
        #expect(pasted.type == type.identifier)
        let before = try Self.read(photo), after = try Self.read(pasted.data)
        #expect((after.width, after.height) == (320, 240))
        #expect(after.pixels == before.pixels, "the same pixels")
        #expect(after.metadata == [])
    }

    /// Text a file carries outside the metadata ImageIO reads (a JPEG comment and a JFXX extension
    /// segment, PNG text chunks) never reaches the Mac: the sent bytes do not hold it, and the image
    /// still reads whole.
    @Test(arguments: [UTType.jpeg, .png])
    func textOutsideTheMetadataIsNotSent(_ type: UTType) throws {
        let clean = try Self.photo(type, width: 320, height: 240, alpha: false)
        let secret = "SpotPlace-Golden-Gate-Park"
        let photo = type == .jpeg
            ? Self.withJPEGSegment(Self.withJPEGComment(clean, secret), marker: 0xE0, payload: Array("JFXX\0".utf8) + [0x13] + Array(secret.utf8))
            : try Self.withPNGText(clean, secret)
        #expect(photo.range(of: Data(secret.utf8)) != nil, "the test photo holds the text")
        #expect((try Self.read(photo).width, try Self.read(photo).height) == (320, 240), "and still reads")
        let pasted = try #require(PastedImage(photo: photo))
        #expect(pasted.data.range(of: Data(secret.utf8)) == nil, "\(type.identifier): the text is not sent")
        if type == .png {
            for chunk in ["tEXt", "iTXt", "zTXt"] {
                #expect(pasted.data.range(of: Data(chunk.utf8)) == nil, "no \(chunk) chunk")
            }
        }
        let read = try Self.read(pasted.data)
        #expect((read.width, read.height) == (320, 240))
        #expect(read.isRed(.topLeft) && !read.isRed(.bottomRight))
    }

    /// What ImageIO's own encoders write for a decoded photo (with an APP1 EXIF and an APP13
    /// Photoshop segment in a JPEG) is rebuilt with the pixel segments only, and reads as the same
    /// image. The message lists the segments before and after.
    @Test(arguments: [(UTType.tiff, UTType.jpeg), (.jpeg, .jpeg), (.tiff, .png), (.png, .png)])
    func theEncodersOwnSegmentsAreDropped(_ source: UTType, _ output: UTType) throws {
        let photo = try Self.photo(source, width: 64, height: 48, alpha: false, orientation: 6, location: .camera)
        let image = try #require(CGImageSourceCreateWithData(photo as CFData, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
            ] as CFDictionary)
        })
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, output.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, (output == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]) as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let before = Self.segments(data as Data, type: output)
        let rebuilt = try #require(PastedImage.pixelSegmentsOnly(data as Data, type: output.identifier), "\(before)")
        let after = Self.segments(rebuilt, type: output)
        let jpegKinds = ["E0", "E2", "DB", "C4", "CC", "DD", "DC", "DA", "EOI"] + (0xC0...0xCF).map { String(format: "%02X", $0) }
        let pngKinds = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "cICP", "sBIT", "bKGD", "pHYs"]
        let allowed = Set(output == .jpeg ? jpegKinds : pngKinds)
        let kinds = after.map { String($0.prefix { $0 != "(" && $0 != ":" }) }
        #expect(kinds.allSatisfy(allowed.contains), "\(source.identifier) to \(output.identifier): \(before) became \(after)")
        #expect(!after.contains { $0.contains("Exif") || $0.contains("Photoshop") || $0.hasPrefix("eXIf") })
        #expect(try Self.read(rebuilt).pixels == (try Self.read(data as Data)).pixels, "the same pixels")
        #expect(try Self.read(rebuilt).metadata == [])
    }

    /// The segments (JPEG: marker and the payload's first bytes) or chunks (PNG) of `data`, in order.
    static func segments(_ data: Data, type: UTType) -> [String] {
        let bytes = [UInt8](data)
        var found: [String] = []
        if type == .png {
            var index = 8
            while index + 8 <= bytes.count, found.count < 64 {
                let length = bytes[index..<index + 4].reduce(0) { $0 << 8 | Int($1) }
                let name = String(decoding: bytes[index + 4..<index + 8], as: UTF8.self)
                found.append("\(name)(\(length))")
                if name == "IEND" { break }
                index += 12 + length
            }
            return found
        }
        var index = 2
        while index + 1 < bytes.count, found.count < 64 {
            let marker = bytes[index + 1]
            if bytes[index] != 0xFF { found.append("not-a-marker@\(index)"); break }
            if marker == 0xD9 { found.append("EOI"); break }
            if marker == 0x01 || (0xD0...0xD7).contains(marker) || marker == 0xFF { index += marker == 0xFF ? 1 : 2; continue }
            if index + 3 >= bytes.count { found.append("truncated@\(index)/\(bytes.count)"); break }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let head = bytes[min(index + 4, bytes.count)..<min(index + 4 + 12, bytes.count)]
            found.append(String(format: "%02X", marker) + "(\(length)):" + head.map { (32...126).contains($0) ? String(UnicodeScalar($0)) : "." }.joined())
            index += 2 + length
            if marker == 0xDA {
                while index + 1 < bytes.count,
                      !(bytes[index] == 0xFF && bytes[index + 1] != 0 && !(0xD0...0xD7).contains(bytes[index + 1]) && bytes[index + 1] != 0xFF) {
                    index += 1
                }
            }
        }
        return found
    }

    /// `jpeg` with a comment segment (COM) holding `text`, right after its start marker.
    static func withJPEGComment(_ jpeg: Data, _ text: String) -> Data {
        withJPEGSegment(jpeg, marker: 0xFE, payload: Array(text.utf8))
    }

    /// `jpeg` with a segment `marker` holding `payload`, right after its start marker.
    static func withJPEGSegment(_ jpeg: Data, marker: UInt8, payload: [UInt8]) -> Data {
        let length = payload.count + 2
        var out = Data(jpeg.prefix(2))
        out.append(contentsOf: [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
        out.append(jpeg.dropFirst(2))
        return out
    }

    /// `jpeg` with its JFIF APP0 segment replaced by one that holds a `width` x `height` RGB
    /// thumbnail of `fill` bytes (an old picture a camera or editor left there).
    static func withJFIFThumbnail(_ jpeg: Data, width: UInt8, height: UInt8, fill: UInt8) throws -> Data {
        let bytes = [UInt8](jpeg)
        try #require(bytes.count > 6 && bytes[2] == 0xFF && bytes[3] == 0xE0, "the test JPEG starts with APP0")
        let oldEnd = 4 + (Int(bytes[4]) << 8 | Int(bytes[5]))
        let payload = Array("JFIF\0".utf8) + [1, 1, 0, 0, 72, 0, 72, width, height]
            + [UInt8](repeating: fill, count: 3 * Int(width) * Int(height))
        let length = payload.count + 2
        return Data(bytes[0..<2] + [0xFF, 0xE0, UInt8(length >> 8), UInt8(length & 0xFF)] + payload + bytes[oldEnd...])
    }

    /// An old picture in a JPEG's JFIF thumbnail, or in a JFXX extension segment (which exists only
    /// for thumbnails), never reaches the Mac: the sent file holds no thumbnail bytes, its JFIF
    /// segment (when kept) says 0 x 0, and the image still reads whole.
    @Test func aJpegThumbnailIsNotSent() throws {
        let clean = try Self.photo(.jpeg, width: 320, height: 240, alpha: false, location: .gps)
        let marker = [UInt8](repeating: 0xA7, count: 48)
        let thumbnailed = try Self.withJFIFThumbnail(clean, width: 16, height: 16, fill: 0xA7)
        let extended = Self.withJPEGSegment(clean, marker: 0xE0, payload: Array("JFXX\0".utf8) + [0x13, 16, 16]
            + [UInt8](repeating: 0xA7, count: 3 * 16 * 16))
        for photo in [thumbnailed, extended] {
            #expect(photo.range(of: Data(marker)) != nil, "the test photo holds a thumbnail")
            let pasted = try #require(PastedImage(photo: photo))
            #expect(pasted.data.range(of: Data(marker)) == nil, "no thumbnail bytes are sent")
            #expect(pasted.data.range(of: Data("JFXX".utf8)) == nil, "no JFXX segment")
            let segments = Self.segments(pasted.data, type: .jpeg)
            for jfif in segments where jfif.hasPrefix("E0") {
                #expect(jfif.hasPrefix("E0(16):JFIF"), "a JFIF segment with no thumbnail: \(segments)")
            }
            let read = try Self.read(pasted.data)
            #expect((read.width, read.height) == (320, 240))
            #expect(read.isRed(.topLeft) && !read.isRed(.bottomRight))
        }
    }

    /// A damaged JPEG or PNG is refused, and nothing is sent: a segment longer than the file, a
    /// scan cut off before the end of the image, a PNG chunk whose length runs past the file.
    @Test(arguments: ["segment length past the end", "truncated scan", "PNG chunk length past the end"])
    func aDamagedFileIsRefused(_ damage: String) throws {
        let jpeg = [UInt8](try Self.photo(.jpeg, width: 320, height: 240, alpha: false, location: .gps))
        let png = [UInt8](try Self.photo(.png, width: 320, height: 240, alpha: false, location: .gps))
        let photo: [UInt8]
        switch damage {
        case "segment length past the end":
            // A comment segment whose length says 65,000 bytes, in a file far shorter.
            photo = Array(jpeg[0..<2]) + [0xFF, 0xFE, 0xFD, 0xE8] + Array("cut".utf8) + Array(jpeg[2...])
        case "truncated scan":
            // The file ends partway through the scan's coded data: no end-of-image marker.
            let start = try #require((0..<jpeg.count - 1).first { jpeg[$0] == 0xFF && jpeg[$0 + 1] == 0xDA })
            photo = Array(jpeg[0..<(start + (jpeg.count - start) / 2)])
        default:
            // The IDAT chunk's length is made larger than the rest of the file.
            let idat = try #require((8..<png.count - 4).first { Array(png[$0..<$0 + 4]) == Array("IDAT".utf8) })
            var damaged = png
            damaged.replaceSubrange((idat - 4)..<idat, with: [0x7F, 0xFF, 0xFF, 0xFF])
            photo = damaged
        }
        #expect(PastedImage(photo: Data(photo)) == nil, "\(damage): refused")
    }

    /// `png` with a tEXt, an iTXt and a zTXt chunk whose keywords and text hold `text`, right after
    /// its header chunk.
    static func withPNGText(_ png: Data, _ text: String) throws -> Data {
        let bytes = [UInt8](png)
        let headerEnd = 8 + 4 + 4 + 13 + 4
        try #require(bytes.count > headerEnd && Array(bytes[12..<16]) == Array("IHDR".utf8))
        let keyword = Array(text.utf8)
        // zTXt: keyword, 0, method 0, then zlib data (a stored block holding the text).
        let stored: [UInt8] = [0x78, 0x01, 0x01, UInt8(keyword.count & 0xFF), UInt8(keyword.count >> 8),
                               UInt8(~keyword.count & 0xFF), UInt8((~keyword.count >> 8) & 0xFF)] + keyword
            + Self.adler32(keyword)
        var out = Array(bytes[0..<headerEnd])
        out += Self.chunk("tEXt", keyword + [0] + keyword)
        out += Self.chunk("iTXt", keyword + [0, 0, 0, 0, 0] + keyword)
        out += Self.chunk("zTXt", keyword + [0, 0] + stored)
        out += bytes[headerEnd...]
        return Data(out)
    }

    static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let length = UInt32(data.count)
        let body = Array(type.utf8) + data
        let crc = crc32(body)
        return [UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
            + body + [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static func adler32(_ bytes: [UInt8]) -> [UInt8] {
        var (a, b): (UInt32, UInt32) = (1, 0)
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let sum = (b << 16) | a
        return [UInt8(sum >> 24), UInt8((sum >> 16) & 0xFF), UInt8((sum >> 8) & 0xFF), UInt8(sum & 0xFF)]
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
            #expect(read.metadata == [], "\(type.identifier) \(orientation): no metadata")
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
        #expect(read.metadata == [])
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
