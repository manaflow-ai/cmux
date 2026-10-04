import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Hashing, the blob cache layout and media inspection for attachments.
/// Every function here is nonisolated and async, so callers on the main
/// actor run the work on the global executor.
enum AttachmentMedia {
    /// Streams `chunkSize` bytes at a time, so a large video is never read
    /// into memory whole.
    static let chunkSize = 1 << 20

    static func sha256Hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String { sha256Hex(SHA256.hash(data: data)) }

    /// SHA-256 of a file, streamed.
    static func sha256(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return sha256Hex(hasher.finalize())
    }

    /// `<root>/<hash>/data.<ext>`: one directory per blob, named by its hash.
    static func blobURL(root: URL, hash: String, fileExtension: String) -> URL {
        let name = fileExtension.isEmpty ? "data" : "data.\(fileExtension)"
        return root.appendingPathComponent(hash, isDirectory: true).appendingPathComponent(name)
    }

    /// Hashes and copies a file into the cache in one streamed pass. Stops
    /// one byte past `maxBytes` (the file grew after its size was read) and
    /// throws `tooLarge`, leaving nothing in the cache.
    static func ingest(fileURL: URL, root: URL,
                       maxBytes: Int = HomeAttachmentPolicy.maxBytes) throws -> (hash: String, url: URL, byteCount: Int) {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let temp = root.appendingPathComponent(".incoming-\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        var moved = false
        defer { if !moved { try? fm.removeItem(at: temp) } }
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temp)
        var hasher = SHA256()
        var count = 0
        do {
            while let chunk = try input.read(upToCount: min(chunkSize, maxBytes + 1 - count)), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
                count += chunk.count
                if count > maxBytes { throw HomeAttachmentError.tooLarge(byteCount: count, limit: maxBytes) }
            }
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        let hash = sha256Hex(hasher.finalize())
        let destination = blobURL(root: root, hash: hash, fileExtension: fileURL.pathExtension.lowercased())
        try place(temp, at: destination)
        moved = true
        return (hash, destination, count)
    }

    static func ingest(data: Data, fileExtension: String, root: URL) throws -> (hash: String, url: URL) {
        let hash = sha256(of: data)
        let destination = blobURL(root: root, hash: hash, fileExtension: fileExtension)
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } else {
            touch(destination.deletingLastPathComponent())
        }
        return (hash, destination)
    }

    /// Marks a blob directory as used now (the cache prunes the least
    /// recently used first).
    static func touch(_ directory: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    /// Bytes of every file under `directory`.
    static func directorySize(_ directory: URL) -> Int {
        guard let items = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in items {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    /// Moves a finished temp file into place; a blob already cached wins
    /// (same hash, same bytes).
    private static func place(_ temp: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: temp)
            touch(destination.deletingLastPathComponent())
            return
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: temp, to: destination)
        } catch where fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: temp) // a concurrent ingest of the same bytes won
        }
    }

    static func mimeType(for type: UTType?) -> String {
        type?.preferredMIMEType ?? "application/octet-stream"
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

    /// True when the image may show through: ImageIO reports
    /// `kCGImagePropertyHasAlpha`, or `sample` (a decoded copy) has an
    /// alpha channel with a pixel that is not fully opaque.
    static func isTransparent(_ source: CGImageSource, sample: CGImage?) -> Bool {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        if (properties?[kCGImagePropertyHasAlpha] as? Bool) == true { return true }
        guard let sample else { return false }
        switch sample.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return !isOpaque(sample)
        }
    }

    /// Every pixel's alpha is 255 (drawn into a cleared RGBA buffer).
    private static func isOpaque(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return true }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
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
    /// which some readers cannot decode), when it is transparent (a JPEG
    /// has no alpha, and the owner keeps the first preview of a hash for
    /// good; readers load the original), or when no attempt fits.
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

    // MARK: Video and audio

    struct Movie {
        var width: Int?
        var height: Int?
        var durationMs: Int?
        var poster: CGImage?
    }

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
        movie.poster = try? await generator.image(at: .zero).image
        return movie
    }

    // MARK: Prepare

    /// The owner's mime type for a file extension: the allow list's own
    /// table first, then the OS's UTType.
    static func mimeType(forExtension fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        if let known = HomeAttachmentPolicy.extensionTypes[ext] { return known }
        return HomeAttachmentPolicy.canonicalMimeType(mimeType(for: UTType(filenameExtension: ext)))
    }

    /// Checks the policy, then copies the bytes into the cache and fills the
    /// ref. Opens a security-scoped URL (the iOS file importer's) for the
    /// copy. Removes location metadata unless `keepLocation`. `name`
    /// defaults to the file's own name. `@concurrent`: hashing 100 MB never
    /// runs on the caller's actor.
    @concurrent
    static func prepare(fileURL: URL, root: URL, name: String? = nil, keepLocation: Bool = false) async throws -> LocalAttachment {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let name = HomeAttachmentPolicy.sendableName(name ?? fileURL.lastPathComponent)
        let mime: String
        switch HomeAttachmentPolicy.decision(forFileExtension: fileURL.pathExtension) {
        case .send(let owned):
            mime = owned
        case .convert:
            guard let converted = try convertedImage({ CGImageSourceCreateWithURL(fileURL as CFURL, nil) }) else {
                throw HomeAttachmentError.typeRefused(mimeType: mimeType(forExtension: fileURL.pathExtension), name: name)
            }
            let base = (name as NSString).deletingPathExtension
            return try await prepare(data: converted.data, typeIdentifier: converted.type.identifier, root: root,
                                     name: "\(base).\(converted.fileExtension)", keepLocation: keepLocation)
        case .refuse:
            mime = mimeType(forExtension: fileURL.pathExtension)
        }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try HomeAttachmentPolicy.check(mimeType: mime, byteCount: size, name: name)
        if !keepLocation {
            if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
               let clean = try imageWithoutLocation(source, name: name) {
                return try await prepare(data: clean.data, typeIdentifier: clean.type.identifier, root: root,
                                         name: renamed(name, mimeType: mime, as: clean.type), keepLocation: true)
            }
            if hasMovieMetadata(mime), let clean = try await movieWithoutLocation(fileURL, mimeType: mime, name: name, root: root) {
                defer { try? FileManager.default.removeItem(at: clean) }
                return try await prepare(fileURL: clean, root: root, name: name, keepLocation: true)
            }
        }
        let (hash, cached, byteCount) = try ingest(fileURL: fileURL, root: root)
        return try await describe(cached: cached, hash: hash, byteCount: byteCount, name: name, mimeType: mime, root: root)
    }

    /// Types whose location lives in movie metadata: video, and M4A audio
    /// (the same container, the same ISO 6709 items).
    static func hasMovieMetadata(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("video/") || mimeType == "audio/mp4"
    }

    /// `name` with the extension of `type` when stripping converted the
    /// image to another type (a WebP sent as PNG).
    static func renamed(_ name: String, mimeType: String, as type: UTType) -> String {
        guard HomeAttachmentPolicy.canonicalMimeType(type.preferredMIMEType ?? "") != mimeType,
              let fileExtension = type.preferredFilenameExtension else { return name }
        return "\((name as NSString).deletingPathExtension).\(fileExtension == "jpeg" ? "jpg" : fileExtension)"
    }

    /// `name` defaults to `attachment.<ext>`. Removes location metadata
    /// unless `keepLocation`.
    @concurrent
    static func prepare(data: Data, typeIdentifier: String, root: URL, name: String? = nil,
                        keepLocation: Bool = false) async throws -> LocalAttachment {
        let type = UTType(typeIdentifier)
        let fileExtension = type?.preferredFilenameExtension ?? ""
        let mime: String
        switch type.map(HomeAttachmentPolicy.decision(for:)) ?? .refuse {
        case .send(let owned):
            mime = owned
        case .convert:
            if let converted = try convertedImage({ CGImageSourceCreateWithData(data as CFData, nil) }) {
                return try await prepare(data: converted.data, typeIdentifier: converted.type.identifier, root: root,
                                         name: name ?? "attachment.\(converted.fileExtension)", keepLocation: keepLocation)
            }
            mime = HomeAttachmentPolicy.canonicalMimeType(mimeType(for: type)) // unreadable bytes: refused below
        case .refuse:
            mime = HomeAttachmentPolicy.canonicalMimeType(mimeType(for: type))
        }
        let name = HomeAttachmentPolicy.sendableName(name ?? (fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"))
        try HomeAttachmentPolicy.check(mimeType: mime, byteCount: data.count, name: name)
        if !keepLocation {
            if mime.hasPrefix("image/"), let source = CGImageSourceCreateWithData(data as CFData, nil),
               let clean = try imageWithoutLocation(source, name: name) {
                let typeIdentifier = clean.type.identifier == UTType(mimeType: mime)?.identifier ? typeIdentifier : clean.type.identifier
                return try await prepare(data: clean.data, typeIdentifier: typeIdentifier, root: root,
                                         name: renamed(name, mimeType: mime, as: clean.type), keepLocation: true)
            }
            if hasMovieMetadata(mime) {
                // AVFoundation reads files: inspect the bytes through a temp file.
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                // The temp file's extension decides its type on the file path.
                let tempExtension = switch mime {
                case "audio/mp4": "m4a"
                case "video/quicktime": "mov"
                default: "mp4"
                }
                let temp = root.appendingPathComponent(".incoming-\(UUID().uuidString).\(tempExtension)")
                try data.write(to: temp)
                defer { try? FileManager.default.removeItem(at: temp) }
                return try await prepare(fileURL: temp, root: root, name: name, keepLocation: false)
            }
        }
        let (hash, cached) = try ingest(data: data, fileExtension: fileExtension, root: root)
        return try await describe(cached: cached, hash: hash, byteCount: data.count, name: name, mimeType: mime, root: root)
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
    /// XMP location tags), orientation and all other metadata kept. It is
    /// copied without re-encoding when ImageIO can, else re-encoded in its
    /// own type, else (a type ImageIO cannot write, such as WebP, or a
    /// HEIC encode that fails) converted to PNG when it has alpha, else
    /// JPEG. Nil when the image has no location. Throws
    /// `HomeAttachmentError.locationNotRemoved` rather than send a
    /// location it could not remove.
    static func imageWithoutLocation(_ source: CGImageSource, name: String) throws -> (data: Data, type: UTType)? {
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
        let hasAlpha = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyHasAlpha] as? Bool ?? false
        let target: UTType = hasAlpha ? .png : .jpeg
        if let data = reencoded(source, as: target.identifier as CFString, frames: 1, verified: verified) { return (data, target) }
        throw HomeAttachmentError.locationNotRemoved(name: name)
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

    /// Media facts are best effort: a file whose media cannot be read still
    /// sends, without a size, duration or poster.
    private static func describe(cached: URL, hash: String, byteCount: Int, name: String, mimeType: String,
                                 root: URL) async throws -> LocalAttachment {
        var ref = AttachmentRef(hash: hash, name: name, mimeType: mimeType, byteCount: byteCount)
        var posterURL: URL?
        var previewURL: URL?
        if mimeType.hasPrefix("image/"), let size = imageDisplaySize(cached) {
            ref.width = size.width
            ref.height = size.height
            if let preview = previewJPEG(of: cached, mimeType: mimeType, byteCount: byteCount, displaySize: size) {
                let (previewHash, url) = try ingest(data: preview, fileExtension: "jpg", root: root)
                ref.preview = AttachmentDerivedImage(hash: previewHash, mimeType: "image/jpeg", byteCount: preview.count)
                previewURL = url
            }
        } else if mimeType.hasPrefix("video/") || mimeType.hasPrefix("audio/"), let movie = try? await inspectMovie(cached) {
            ref.width = movie.width
            ref.height = movie.height
            ref.durationMs = movie.durationMs
            // A poster over the owner's cap is dropped: the video still sends.
            if mimeType.hasPrefix("video/"), let poster = movie.poster, let posterData = try? jpeg(poster),
               posterData.count <= HomeAttachmentPolicy.posterMaxBytes {
                let (posterHash, url) = try ingest(data: posterData, fileExtension: "jpg", root: root)
                ref.poster = AttachmentPoster(hash: posterHash, mimeType: "image/jpeg", byteCount: posterData.count)
                posterURL = url
            }
        }
        return LocalAttachment(ref: HomeAttachmentPolicy.normalized(ref), fileURL: cached, posterURL: posterURL,
                               previewURL: previewURL)
    }

    /// A cached thumbnail next to the blob (`thumb-<maxPixel>.jpg`, or
    /// `.png` for a transparent image).
    static func localThumbnail(of files: LocalAttachmentFiles, ref: AttachmentRef, maxPixel: Int) throws -> URL {
        let sourceURL: URL
        if let poster = files.posterURL {
            sourceURL = poster
        } else if let preview = files.previewURL, maxPixel <= HomeAttachmentPolicy.previewMaxPixel {
            sourceURL = preview // smaller to decode than the original
        } else if ref.mimeType.hasPrefix("image/") {
            sourceURL = files.fileURL
        } else {
            throw HomeRejection.invalid("no_thumbnail")
        }
        let directory = files.fileURL.deletingLastPathComponent()
        for fileExtension in ["jpg", "png"] {
            let cached = directory.appendingPathComponent("thumb-\(maxPixel).\(fileExtension)")
            if FileManager.default.fileExists(atPath: cached.path) { return cached }
        }
        let thumb = try thumbnail(of: sourceURL, maxPixel: maxPixel)
        try Task.checkCancellation()
        let target = directory.appendingPathComponent("thumb-\(maxPixel).\(thumb.fileExtension)")
        try thumb.data.write(to: target, options: .atomic)
        return target
    }
}
