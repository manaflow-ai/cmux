import CmuxScreenKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo from the picker, in a form the Mac's pasteboard takes, at its full size, upright in its
/// pixels and with no location in it (not in GPS, IPTC or XMP). A PNG or JPEG that is already
/// upright goes as it is when it names no location; when it names one, ImageIO copies it with no
/// metadata at all and the same pixels (no second lossy encode). Anything else (HEIC, a turned
/// photo, …) is decoded by ImageIO with its orientation applied to the pixels (an agent that reads
/// pixels, not the EXIF tag, sees it the right way up), and written as PNG when it has transparency
/// or was a PNG (lossless, so the same pixels), JPEG otherwise, with orientation 1 and no other
/// metadata. A photo whose pixel size ImageIO cannot
/// read is refused. No UIKit drawing context is made. No size limit: the image goes to the Mac in
/// chunks (``ScreenInput/pasteImageChunks(_:type:id:)``). Builds on macOS too, so its tests run there.
struct PastedImage: Sendable, Equatable {
    let data: Data
    /// The uniform type identifier (`public.png`, `public.jpeg`).
    let type: String

    init(data: Data, type: String) {
        self.data = data
        self.type = type
    }

    /// Nil when `photo` is no image, or cannot be converted.
    init?(photo: Data) {
        guard let source = CGImageSourceCreateWithData(photo as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        self.init(photo: photo, source: source, properties: properties)
    }

    /// `photo` prepared from its `source` and the first image's `properties` as ImageIO read them
    /// (the tests give properties ImageIO seldom reads, such as none for the pixel size).
    init?(photo: Data, source: CGImageSource, properties: [CFString: Any]) {
        // With no pixel size ImageIO would make a 1-pixel image: refuse it (the app says so).
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let upright = (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
        if upright, let type = Self.passThroughType(of: photo) {
            if !Self.namesALocation(source, properties: properties) {
                self.init(data: photo, type: type)
                return
            }
            if let copied = Self.copyWithNoMetadata(source, type: type) {
                self.init(data: copied, type: type)
                return
            }
        }
        let lossless = Self.passThroughType(of: photo) == UTType.png.identifier
        guard let converted = Self.convert(source, properties: properties, width: width, height: height, lossless: lossless)
        else { return nil }
        self = converted
    }

    /// Whether the first image names where it was taken: a GPS dictionary, an IPTC place, or an XMP
    /// GPS or place tag (`exif:GPS…`, `photoshop:City`, `Iptc4xmpCore:Location`, …).
    static func namesALocation(_ source: CGImageSource, properties: [CFString: Any]) -> Bool {
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
           [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
            kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode]
               .contains(where: { iptc[$0] != nil }) { return true }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return false }
        return tags.contains { tag in
            guard let name = CGImageMetadataTagCopyName(tag) as String? else { return false }
            return name.hasPrefix("GPS") || placeTagNames.contains(name)
        }
    }

    /// XMP tag names (photoshop, IPTC Core and IPTC Extension) that name a place.
    private static let placeTagNames: Set<String> = [
        "City", "State", "Country", "CountryCode", "CountryName", "Location", "LocationCreated", "LocationShown",
        "Sublocation", "ProvinceState", "WorldRegion",
    ]

    /// The first image of an upright PNG or JPEG `source` with its pixels as they are and no
    /// metadata (EXIF, GPS, IPTC, XMP); nil when ImageIO cannot copy it so, or the copy still names
    /// a location (the caller then decodes and re-encodes it).
    private static func copyWithNoMetadata(_ source: CGImageSource, type: String) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else { return nil }
        // Empty metadata, not merged, replaces all of it (EXIF, IPTC and XMP). ShouldExcludeXMP is
        // not set: with kCGImageDestinationMetadata it keeps the EXIF and IPTC.
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        // CopyImageSource finalizes the destination itself.
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else { return nil }
        let copied = output as Data
        guard let check = CGImageSourceCreateWithData(copied as CFData, nil), CGImageSourceGetCount(check) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any] ?? [:]
        guard (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, !namesALocation(check, properties: properties) else { return nil }
        return copied
    }

    /// `public.png` or `public.jpeg` from the file's signature; nil for any other format.
    static func passThroughType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "public.png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "public.jpeg" }
        return nil
    }

    /// The photo's first image, turned upright at its full size and re-encoded with no location:
    /// PNG when it has transparency or is `lossless` (a PNG stays a PNG, with the same pixels), else JPEG.
    private static func convert(_ source: CGImageSource, properties: [CFString: Any], width: Int, height: Int,
                                lossless: Bool) -> PastedImage? {
        // The full-size "thumbnail" with the transform applies the EXIF orientation to the pixels.
        let upright: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, upright as CFDictionary) else { return nil }
        let transparent = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let png = transparent || lossless
        let type = png ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        // Only what the Mac needs: no GPS, no EXIF (its own copy of the place and the camera), orientation 1.
        var written: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let profile = properties[kCGImagePropertyProfileName] { written[kCGImagePropertyProfileName] = profile }
        if !png { written[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, written as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PastedImage(data: output as Data, type: type.identifier)
    }
}
