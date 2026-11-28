import CmuxScreenKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo from the picker, in a form the Mac's pasteboard takes, at its full size, upright in its
/// pixels and with no metadata in it: no EXIF, GPS, IPTC, XMP or maker note, whatever its tags are
/// named (an allow-list, so an unknown tag is dropped, never sent).
///
/// An upright PNG or JPEG is copied by ImageIO with empty metadata and the same pixels (no second
/// lossy encode). Anything else (HEIC, a turned photo, a copy ImageIO cannot make clean) is decoded
/// with its orientation applied to the pixels (an agent that reads pixels, not the EXIF tag, sees
/// it the right way up) and written again: PNG when it has transparency or was a PNG (lossless, so
/// the same pixels), JPEG otherwise. On both paths the file is then rebuilt from its pixel segments
/// only (``pixelSegmentsOnly(_:type:)``: no comment, APP1, APP13 or text chunk, by an allow-list of
/// the file's own structure) and read back; anything beyond what describes the pixels sends a copy
/// down the decode path, and a decoded photo is refused. The image's color profile travels with its
/// pixels. A photo whose pixel size ImageIO cannot read is
/// refused. No UIKit drawing context is made. No size limit: the image goes to the Mac in chunks
/// (``ScreenInput/pasteImageChunks(_:type:id:)``). Builds on macOS too, so its tests run there.
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
        let format = Self.passThroughType(of: photo)
        // A damaged JPEG or PNG is refused, never decoded: what a decoder makes of it is not the photo.
        if let format, Self.isDamaged(photo, type: format) { return nil }
        if upright, let format, let copied = Self.copyWithNoMetadata(source, type: format) {
            self.init(data: copied, type: format)
            return
        }
        let lossless = format == UTType.png.identifier
        guard let converted = Self.convert(source, properties: properties, width: width, height: height, lossless: lossless)
        else { return nil }
        self = converted
    }

    /// What describes only the pixels, by properties dictionary (`{JFIF}` density, `{PNG}` gamma
    /// and color, `{TIFF}` orientation and resolution, and the `{Exif}` color space and pixel size).
    /// Any other dictionary or key is metadata.
    ///
    /// The three `{Exif}` keys are here because ImageIO's PNG and JPEG encoders write them on their
    /// own for any image, also with empty, unmerged metadata, so no image ImageIO writes has no
    /// `{Exif}`. ``carriesMetadata(_:properties:)`` takes them only with the encoder's own values:
    /// the pixel size of the image written, and a color space EXIF defines (1 sRGB, 65535 other).
    private static var pixelOnly: [String: Set<String>] {
        [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifColorSpace, kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
            ].reduce(into: Set<String>()) { $0.insert($1 as String) },
            kCGImagePropertyJFIFDictionary as String: [
                kCGImagePropertyJFIFVersion, kCGImagePropertyJFIFXDensity, kCGImagePropertyJFIFYDensity,
                kCGImagePropertyJFIFDensityUnit, kCGImagePropertyJFIFIsProgressive,
            ].reduce(into: Set<String>()) { $0.insert($1 as String) },
            kCGImagePropertyPNGDictionary as String: [
                kCGImagePropertyPNGGamma, kCGImagePropertyPNGChromaticities, kCGImagePropertyPNGsRGBIntent,
                kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGXPixelsPerMeter, kCGImagePropertyPNGYPixelsPerMeter,
                kCGImagePropertyPNGCompressionFilter,
            ].reduce(into: Set<String>()) { $0.insert($1 as String) },
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution, kCGImagePropertyTIFFYResolution,
                kCGImagePropertyTIFFResolutionUnit,
            ].reduce(into: Set<String>()) { $0.insert($1 as String) },
        ]
    }

    /// Whether the first image of `source` carries anything beyond what describes its pixels: a
    /// dictionary or key not in ``pixelOnly``, an XMP tag other than the `tiff:` and `exif:` mirrors
    /// of those keys, or an orientation other than 1. Fails closed: what it does not know counts as
    /// metadata.
    static func carriesMetadata(_ source: CGImageSource, properties: [CFString: Any]) -> Bool {
        if (properties[kCGImagePropertyOrientation] as? Int ?? 1) != 1 { return true }
        let allowed = pixelOnly
        for (key, value) in properties {
            guard let dictionary = value as? [String: Any] else { continue }
            guard let keys = allowed[key as String], dictionary.keys.allSatisfy(keys.contains) else { return true }
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           (tiff[kCGImagePropertyTIFFOrientation] as? Int ?? 1) != 1 { return true }
        // The {Exif} keys allowed carry the encoder's own values, never ones from the source.
        let encoderValues: [String: Set<Int>] = [
            kCGImagePropertyExifPixelXDimension as String: [properties[kCGImagePropertyPixelWidth] as? Int ?? -1],
            kCGImagePropertyExifPixelYDimension as String: [properties[kCGImagePropertyPixelHeight] as? Int ?? -1],
            kCGImagePropertyExifColorSpace as String: [1, 65535],
        ]
        if let exif = properties[kCGImagePropertyExifDictionary] as? [String: Any],
           exif.contains(where: { key, value in !(encoderValues[key]?.contains(integer(value) ?? -1) ?? false) }) {
            return true
        }
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return false }
        // An XMP tag's prefix names the dictionary it mirrors.
        let mirrored = [
            "tiff": allowed[kCGImagePropertyTIFFDictionary as String] ?? [],
            "exif": allowed[kCGImagePropertyExifDictionary as String] ?? [],
        ]
        let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] ?? []
        return tags.contains { tag in
            let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
            let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
            guard mirrored[prefix]?.contains(name) ?? false else { return true }
            guard prefix == "exif" else { return false }
            return !(encoderValues[name]?.contains(integer(CGImageMetadataTagCopyValue(tag)) ?? -1) ?? false)
        }
    }

    /// `value` as a whole number: an `NSNumber`, or a string of digits (XMP keeps its values as text).
    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// The first image of an upright PNG or JPEG `source`, its pixels as they are, with empty
    /// metadata in place of the source's (not merged, so nothing of it is kept); nil when ImageIO
    /// cannot copy it so or the copy read back still carries metadata (the caller then decodes).
    private static func copyWithNoMetadata(_ source: CGImageSource, type: String) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
        ]
        // CopyImageSource finalizes the destination itself.
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
              let copied = pixelSegmentsOnly(output as Data, type: type) else { return nil }
        guard let check = CGImageSourceCreateWithData(copied as CFData, nil), CGImageSourceGetCount(check) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
              !carriesMetadata(check, properties: properties) else { return nil }
        return copied
    }

    /// `public.png` or `public.jpeg` from the file's signature; nil for any other format.
    static func passThroughType(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(8))
        if bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "public.png" }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "public.jpeg" }
        return nil
    }

    /// The photo's first image, turned upright at its full size and written again with no
    /// metadata: PNG when it has transparency or is `lossless` (a PNG stays a PNG, with the same
    /// pixels), else JPEG.
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
        // No properties but the JPEG quality: no orientation tag (none means upright) and no metadata.
        // The color profile is the image's color space, written with its pixels.
        let written: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, written as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        // ImageIO's JPEG encoder writes segments of its own (APP1 EXIF, APP13 Photoshop): rebuilt
        // from the pixel segments only, then read back like a copy, so nothing is sent unchecked.
        guard let written = pixelSegmentsOnly(output as Data, type: type.identifier),
              let check = CGImageSourceCreateWithData(written as CFData, nil), CGImageSourceGetCount(check) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
              !carriesMetadata(check, properties: properties) else { return nil }
        return PastedImage(data: written, type: type.identifier)
    }
}
