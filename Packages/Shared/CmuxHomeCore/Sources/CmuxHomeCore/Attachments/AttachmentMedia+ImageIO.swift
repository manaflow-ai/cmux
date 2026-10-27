#if canImport(ImageIO)
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The media readers of ``AttachmentMedia`` on Apple platforms: ImageIO for
/// images, AVFoundation for video and audio.
extension AttachmentMedia {
    /// The image types ImageIO reads (``HomeAttachmentPolicy/convertibleImageTypes``).
    static var readableImageTypeIdentifiers: [String] {
        (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
    }

    // MARK: Images

    /// Display size: orientations 5 through 8 rotate by 90 degrees.
    static func imageDisplaySize(_ url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// The image whose longer side is at most `maxPixel`, orientation applied.
    private static func thumbnailImage(of url: URL, maxPixel: Int) throws -> (source: CGImageSource, image: CGImage) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw HomeRejection.invalid("not_an_image") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw HomeRejection.invalid("not_an_image")
        }
        return (source, image)
    }

    /// A JPEG whose longer side is at most `maxPixel`, orientation applied.
    static func thumbnailJPEG(of url: URL, maxPixel: Int, quality: Double = 0.85) throws -> Data {
        try jpeg(thumbnailImage(of: url, maxPixel: maxPixel).image, quality: quality)
    }

    /// A thumbnail whose longer side is at most `maxPixel`: PNG when the
    /// image is transparent (a JPEG would fill it black), else JPEG.
    static func thumbnail(of url: URL, maxPixel: Int) throws -> (data: Data, fileExtension: String) {
        let (source, image) = try thumbnailImage(of: url, maxPixel: maxPixel)
        if isTransparent(source, sample: image) { return (try png(image), "png") }
        return (try jpeg(image), "jpg")
    }

    /// True when the image really shows through: `sample` (a decoded copy,
    /// at most 512 px for a preview) has a pixel that is not fully opaque.
    /// `kCGImagePropertyHasAlpha` only says an alpha channel exists; many
    /// opaque PNGs have one, so the pixels decide. Without a sample, or when
    /// the decoder dropped the channel, the flag decides.
    static func isTransparent(_ source: CGImageSource, sample: CGImage?) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? Bool) == true
        guard let sample else { return hasAlpha }
        switch sample.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return hasAlpha
        default: return !isOpaque(sample)
        }
    }

    /// Every pixel's alpha is 255 (drawn into a cleared RGBA buffer).
    private static func isOpaque(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height, byteCount = width * height * 4
        guard width > 0, height > 0, byteCount > 0 else { return true }
        var pixels = [UInt8](repeating: 0, count: byteCount)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }
    }

    /// An image's preview: a JPEG at most `previewMaxPixel` on its long edge
    /// and `previewMaxBytes`, trying lower quality and size before giving
    /// up. Nil when the image is small enough to show itself (and not HEIC,
    /// which some readers cannot decode), when a pixel of its 512 px sample
    /// is transparent (Lawrence's rule: transparent images get no preview;
    /// a JPEG has no alpha, and the owner keeps the first preview of a hash
    /// for good; readers load the original), or when no attempt fits. An
    /// opaque image with an alpha channel gets a preview.
    static func previewJPEG(of url: URL, mimeType: String, byteCount: Int, displaySize: (width: Int, height: Int)) -> Data? {
        let maxPixel = HomeAttachmentPolicy.previewMaxPixel
        let maxBytes = HomeAttachmentPolicy.previewMaxBytes
        if mimeType != "image/heic", max(displaySize.width, displaySize.height) <= maxPixel, byteCount <= maxBytes { return nil }
        guard let sample = try? thumbnailImage(of: url, maxPixel: 512),
              !isTransparent(sample.source, sample: sample.image) else { return nil }
        for (pixels, quality) in [(maxPixel, 0.8), (maxPixel, 0.6), (maxPixel * 3 / 4, 0.6), (maxPixel / 2, 0.6)] {
            if let data = try? thumbnailJPEG(of: url, maxPixel: pixels, quality: quality), data.count <= maxBytes { return data }
        }
        return nil
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.85) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    /// An image in a type the owner refuses but ImageIO reads (a pasted
    /// macOS screenshot is TIFF, an iPhone photo can be HEIF): re-encoded
    /// as PNG when it has alpha, else JPEG, with its orientation and other
    /// metadata kept. Nil when `type` is not such an image.
    static func convertedImage(_ makeSource: () -> CGImageSource?) throws -> (data: Data, type: UTType, fileExtension: String)? {
        guard let source = makeSource(), CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? Bool) ?? false
        let target: UTType = hasAlpha ? .png : .jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, target.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let options: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw HomeRejection.invalid("not_an_image") }
        return (data as Data, target, hasAlpha ? "png" : "jpg")
    }

    /// ``convertedImage(_:)`` for a file.
    static func convertedImage(fileURL: URL) throws -> (data: Data, type: UTType, fileExtension: String)? {
        guard let converted = try convertedImage({ CGImageSourceCreateWithURL(fileURL as CFURL, nil) }) else {
            return nil
        }
        return converted
    }

    /// ``convertedImage(_:)`` for in-memory bytes.
    static func convertedImage(data: Data) throws -> (data: Data, type: UTType, fileExtension: String)? {
        try convertedImage { CGImageSourceCreateWithData(data as CFData, nil) }
    }

    // MARK: Video and audio

    /// Duration, display size (preferred transform applied) and the first
    /// frame as a poster. Audio-only files get a duration only.
    @concurrent
    static func inspectMovie(_ url: URL, posterMaxPixel: Int = 1280) async throws -> Movie {
        let asset = AVURLAsset(url: url)
        var movie = Movie()
        let duration = try await asset.load(.duration)
        if duration.isNumeric, duration.seconds.isFinite {
            movie.durationMs = Int((duration.seconds * 1000).rounded())
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return movie }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let display = CGRect(origin: .zero, size: natural).applying(transform)
        movie.width = Int(abs(display.width).rounded())
        movie.height = Int(abs(display.height).rounded())
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: posterMaxPixel, height: posterMaxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        if let poster = try? await generator.image(at: .zero).image { movie.posterJPEG = try? jpeg(poster) }
        return movie
    }

    // MARK: Location

    /// IPTC keys that hold a place as text.
    static var iptcLocationKeys: [CFString] {
        [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
         kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
         kCGImagePropertyIPTCContentLocationName, kCGImagePropertyIPTCContentLocationCode]
    }

    /// An XMP tag that holds a position or a place: EXIF GPS tags, the
    /// Photoshop and IPTC Core place names, and the IPTC Extension
    /// location structures.
    static func isLocationTag(_ tag: CGImageMetadataTag) -> Bool {
        let prefix = CGImageMetadataTagCopyPrefix(tag) as String? ?? ""
        let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
        switch prefix {
        case "exif": return name.hasPrefix("GPS")
        case "photoshop": return ["City", "State", "Country"].contains(name)
        case "Iptc4xmpCore": return ["Location", "CountryCode"].contains(name)
        case "Iptc4xmpExt": return ["LocationShown", "LocationCreated"].contains(name)
        default: return false
        }
    }

    /// Image `index`'s XMP view (which ImageIO also fills from EXIF and
    /// IPTC) without location tags, and whether it had any.
    static func metadataWithoutLocation(_ source: CGImageSource, at index: Int) -> (metadata: CGImageMetadata?, hadLocation: Bool) {
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil) else { return (nil, false) }
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            if isLocationTag(tag) { paths.append(path as String) }
            return true
        }
        guard !paths.isEmpty, let cleaned = CGImageMetadataCreateMutableCopy(metadata) else { return (metadata, false) }
        for path in paths { CGImageMetadataRemoveTagWithPath(cleaned, nil, path as CFString) }
        return (cleaned, true)
    }

    /// True when image `index` holds a position or a place anywhere: the
    /// GPS dictionary, IPTC place text, or an XMP location tag.
    static func hasLocation(_ source: CGImageSource, at index: Int) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        if properties[kCGImagePropertyGPSDictionary] != nil { return true }
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        if iptcLocationKeys.contains(where: { iptc[$0] != nil }) { return true }
        return metadataWithoutLocation(source, at: index).hadLocation
    }

    /// The image without location metadata (EXIF GPS, IPTC place text,
    /// XMP location tags). A type ImageIO can write keeps its orientation
    /// and all other metadata: it is copied without re-encoding when
    /// ImageIO can, else re-encoded in its own type. A WebP (ImageIO cannot
    /// write it) keeps its own bytes minus its whole EXIF and XMP chunks
    /// (`webPWithoutMetadataChunks`), so it loses all EXIF and XMP metadata
    /// (camera, date and the rest, not only location) but an animated WebP
    /// keeps its frames and its size; that fails verification when the
    /// EXIF held a rotation, which would be lost. Else (that WebP,
    /// another type ImageIO cannot write, or a HEIC encode that fails) the
    /// first frame is converted to PNG when it has alpha, else JPEG: an
    /// animation keeps only its first frame, and a PNG can be larger than
    /// the original, up to the size limit (then `prepare` refuses it as too
    /// large). Nil when the image has no location. `bytes` reads the
    /// original (only for a WebP). Throws
    /// `HomeAttachmentError.locationNotRemoved` rather than send a
    /// location it could not remove.
    static func imageWithoutLocation(_ source: CGImageSource, name: String,
                                     bytes: () throws -> Data? = { nil }) throws -> (data: Data, type: UTType)? {
        let count = CGImageSourceGetCount(source)
        guard count > 0, (0..<count).contains(where: { hasLocation(source, at: $0) }) else { return nil }
        let orientations = (0..<count).map { index -> Int in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        }
        // The result must have no location and the same orientations.
        func verified(_ data: NSMutableData, frames: Int) -> Data? {
            guard let result = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(result) == frames else { return nil }
            for index in 0..<frames {
                let after = CGImageSourceCopyPropertiesAtIndex(result, index, nil) as? [CFString: Any] ?? [:]
                let kept = (after[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                guard !hasLocation(result, at: index), kept == orientations[index] else { return nil }
            }
            return data as Data
        }
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        if let type = CGImageSourceGetType(source), writable.contains(type as String), let utType = UTType(type as String) {
            // A lossless copy with the cleaned metadata replacing the old.
            let copied = NSMutableData()
            if let destination = CGImageDestinationCreateWithData(copied as CFMutableData, type, count, nil) {
                var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true,
                                                kCGImageDestinationOrientation: orientations[0],
                                                kCGImageDestinationMergeMetadata: false]
                if let metadata = metadataWithoutLocation(source, at: 0).metadata { options[kCGImageDestinationMetadata] = metadata }
                if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
                   let data = verified(copied, frames: count) {
                    return (data, utType)
                }
            }
            if let data = reencoded(source, as: type, frames: count, verified: verified) { return (data, utType) }
        }
        if CGImageSourceGetType(source) as String? == UTType.webP.identifier, let original = try bytes(),
           let stripped = webPWithoutMetadataChunks(original),
           let data = verified(NSMutableData(data: stripped), frames: count) {
            return (data, .webP)
        }
        let hasAlpha = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let target: UTType = hasAlpha ? .png : .jpeg
        if let data = reencoded(source, as: target.identifier as CFString, frames: 1, verified: verified) { return (data, target) }
        throw HomeAttachmentError.locationNotRemoved(name: name)
    }

    /// ``imageWithoutLocation(_:name:bytes:)`` for an image file; nil when
    /// `mime` is not an image type, ImageIO cannot read the file or it has
    /// no location.
    static func imageWithoutLocation(fileURL: URL, mimeType mime: String, name: String) throws -> (data: Data, type: UTType)? {
        if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
           let clean = try imageWithoutLocation(source, name: name, bytes: { try Data(contentsOf: fileURL) }) {
            return clean
        }
        return nil
    }

    /// The same for in-memory bytes.
    static func imageWithoutLocation(data: Data, mimeType mime: String, name: String) throws -> (data: Data, type: UTType)? {
        if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithData(data as CFData, nil),
           let clean = try imageWithoutLocation(source, name: name, bytes: { data }) {
            return clean
        }
        return nil
    }

    /// The first `frames` images encoded as `type` with their metadata
    /// minus location; nil when encoding or verification fails.
    private static func reencoded(_ source: CGImageSource, as type: CFString, frames: Int,
                                  verified: (NSMutableData, Int) -> Data?) -> Data? {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, type, frames, nil) else { return nil }
        for index in 0..<frames {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
            if let metadata = metadataWithoutLocation(source, at: index).metadata {
                CGImageDestinationAddImageAndMetadata(destination, image, metadata, options as CFDictionary)
            } else {
                CGImageDestinationAddImage(destination, image, options as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { return nil }
        return verified(encoded, frames)
    }

    /// A position or place in movie metadata: ISO 6709 (QuickTime metadata
    /// or user data), the common location key, every
    /// `com.apple.quicktime.location.*` key (name, body, note, role, date)
    /// and the 3GPP location box.
    static func isLocation(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyLocation { return true }
        guard let raw = item.identifier?.rawValue else { return false }
        return isLocationIdentifier(raw)
    }

    /// The same test for a metadata identifier (`mdta/...`, `udta/...`).
    static func isLocationIdentifier(_ raw: String) -> Bool {
        raw.hasPrefix("mdta/com.apple.quicktime.location.") || raw == AVMetadataIdentifier.commonIdentifierLocation.rawValue
            || raw == AVMetadataIdentifier.quickTimeUserDataLocationISO6709.rawValue || raw == "udta/loci"
    }

    /// Track types that can carry positions as samples: timed metadata,
    /// and text or subtitles (a drone writes its GPS as subtitles).
    static var locationTrackTypes: Set<AVMediaType> { [.metadata, .text, .subtitle] }

    /// True when a track's samples may hold positions. A text or subtitle
    /// track always may. A timed metadata track may when one of its formats
    /// names a location identifier, or when its format lists no
    /// identifiers to check (GoPro GPMF, camera motion `camm`: these carry
    /// GPS). A boxed track that names only other keys (an iPhone's
    /// orientation, still-image-time or face tracks) holds no location.
    static func trackMayHoldLocation(_ track: AVAssetTrack) async -> Bool {
        switch track.mediaType {
        case .text, .subtitle:
            return true
        case .metadata:
            let formats = (try? await track.load(.formatDescriptions)) ?? []
            guard !formats.isEmpty else { return true }
            for format in formats {
                guard CMFormatDescriptionGetMediaSubType(format) == kCMMetadataFormatType_Boxed,
                      let identifiers = CMMetadataFormatDescriptionGetIdentifiers(format) as? [String] else { return true }
                if identifiers.contains(where: isLocationIdentifier) { return true }
            }
            return false
        default:
            return false
        }
    }

    /// Location anywhere in a movie or M4A: asset or track metadata items,
    /// or a track whose samples may hold positions (`trackMayHoldLocation`).
    static func movieHasLocation(_ asset: AVAsset) async -> Bool {
        if ((try? await asset.load(.metadata)) ?? []).contains(where: isLocation) { return true }
        for track in (try? await asset.load(.tracks)) ?? [] {
            if await trackMayHoldLocation(track) { return true }
            if ((try? await track.load(.metadata)) ?? []).contains(where: isLocation) { return true }
        }
        return false
    }

    /// A copy of the movie (or M4A) without location, written to a temp
    /// file under `root` by a passthrough export (no re-encode), with each
    /// track's transform and the asset metadata that is not location (as
    /// `AVMetadataItemFilter.forSharing` allows); track metadata is not
    /// copied. Timed metadata, text and subtitle tracks are left out
    /// (`locationTrackTypes`). Another track the composition cannot take
    /// (a timecode track, a Cinematic disparity track) is left out too; an
    /// audio or video track it cannot take refuses the file, since the
    /// message would lose its content. Nil when the file has no location.
    /// The caller deletes it. Throws `HomeAttachmentError.locationNotRemoved`
    /// when the export fails or its result still holds a location.
    @concurrent
    static func movieWithoutLocation(_ url: URL, mimeType: String, name: String, root: URL) async throws -> URL? {
        let asset = AVURLAsset(url: url)
        guard await movieHasLocation(asset) else { return nil }
        let refused = HomeAttachmentError.locationNotRemoved(name: name)
        let composition = AVMutableComposition()
        do {
            for track in try await asset.load(.tracks) where !locationTrackTypes.contains(track.mediaType) {
                let essential = track.mediaType == .video || track.mediaType == .audio
                let (range, transform) = try await track.load(.timeRange, .preferredTransform)
                guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                             preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    if essential { throw refused }
                    continue
                }
                do {
                    try copy.insertTimeRange(range, of: track, at: range.start)
                } catch {
                    if essential { throw refused }
                    composition.removeTrack(copy)
                    continue
                }
                copy.preferredTransform = transform
            }
        } catch {
            throw refused
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw refused }
        session.metadata = ((try? await asset.load(.metadata)) ?? []).filter { !isLocation($0) }
        session.metadataItemFilter = .forSharing()
        let (fileType, fileExtension): (AVFileType, String) = switch mimeType {
        case "video/quicktime": (.mov, "mov")
        case "audio/mp4": (.m4a, "m4a")
        default: (.mp4, "mp4")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let output = root.appendingPathComponent(".incoming-\(UUID().uuidString).\(fileExtension)")
        do {
            if #available(macOS 15, iOS 18, *) {
                try await session.export(to: output, as: fileType)
            } else {
                session.outputURL = output
                session.outputFileType = fileType
                await session.export()
                guard session.status == .completed else { throw refused }
            }
            guard await !movieHasLocation(AVURLAsset(url: output)) else { throw refused }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw refused
        }
        return output
    }
}
#endif
