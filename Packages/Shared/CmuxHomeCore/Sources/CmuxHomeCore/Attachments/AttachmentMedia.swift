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

    /// A JPEG whose longer side is at most `maxPixel`, orientation applied.
    static func thumbnailJPEG(of url: URL, maxPixel: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw HomeRejection.invalid("not_an_image") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw HomeRejection.invalid("not_an_image")
        }
        return try jpeg(image)
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
    /// copy. `@concurrent`: hashing 100 MB never runs on the caller's actor.
    @concurrent
    static func prepare(fileURL: URL, root: URL) async throws -> LocalAttachment {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let name = HomeAttachmentPolicy.sendableName(fileURL.lastPathComponent)
        let mime: String
        switch HomeAttachmentPolicy.decision(forFileExtension: fileURL.pathExtension) {
        case .send(let owned):
            mime = owned
        case .convert:
            guard let converted = try convertedImage({ CGImageSourceCreateWithURL(fileURL as CFURL, nil) }) else {
                throw HomeAttachmentError.typeRefused(mimeType: mimeType(forExtension: fileURL.pathExtension), name: name)
            }
            let base = fileURL.deletingPathExtension().lastPathComponent
            return try await prepare(data: converted.data, typeIdentifier: converted.type.identifier, root: root,
                                     name: HomeAttachmentPolicy.sendableName("\(base).\(converted.fileExtension)"))
        case .refuse:
            mime = mimeType(forExtension: fileURL.pathExtension)
        }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try HomeAttachmentPolicy.check(mimeType: mime, byteCount: size, name: name)
        let (hash, cached, byteCount) = try ingest(fileURL: fileURL, root: root)
        return try await describe(cached: cached, hash: hash, byteCount: byteCount, name: name, mimeType: mime, root: root)
    }

    /// `name` defaults to `attachment.<ext>`.
    @concurrent
    static func prepare(data: Data, typeIdentifier: String, root: URL, name: String? = nil) async throws -> LocalAttachment {
        let type = UTType(typeIdentifier)
        let fileExtension = type?.preferredFilenameExtension ?? ""
        let mime: String
        switch type.map(HomeAttachmentPolicy.decision(for:)) ?? .refuse {
        case .send(let owned):
            mime = owned
        case .convert:
            if let converted = try convertedImage({ CGImageSourceCreateWithData(data as CFData, nil) }) {
                return try await prepare(data: converted.data, typeIdentifier: converted.type.identifier, root: root,
                                         name: name ?? "attachment.\(converted.fileExtension)")
            }
            mime = HomeAttachmentPolicy.canonicalMimeType(mimeType(for: type)) // unreadable bytes: refused below
        case .refuse:
            mime = HomeAttachmentPolicy.canonicalMimeType(mimeType(for: type))
        }
        let name = HomeAttachmentPolicy.sendableName(name ?? (fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"))
        try HomeAttachmentPolicy.check(mimeType: mime, byteCount: data.count, name: name)
        let (hash, cached) = try ingest(data: data, fileExtension: fileExtension, root: root)
        return try await describe(cached: cached, hash: hash, byteCount: data.count, name: name, mimeType: mime, root: root)
    }

    /// Media facts are best effort: a file whose media cannot be read still
    /// sends, without a size, duration or poster.
    private static func describe(cached: URL, hash: String, byteCount: Int, name: String, mimeType: String,
                                 root: URL) async throws -> LocalAttachment {
        var ref = AttachmentRef(hash: hash, name: name, mimeType: mimeType, byteCount: byteCount)
        var posterURL: URL?
        if mimeType.hasPrefix("image/"), let size = imageDisplaySize(cached) {
            ref.width = size.width
            ref.height = size.height
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
        return LocalAttachment(ref: HomeAttachmentPolicy.normalized(ref), fileURL: cached, posterURL: posterURL)
    }

    /// A cached thumbnail next to the blob (`thumb-<maxPixel>.jpg`).
    static func localThumbnail(of files: LocalAttachmentFiles, ref: AttachmentRef, maxPixel: Int) throws -> URL {
        let sourceURL: URL
        if let poster = files.posterURL {
            sourceURL = poster
        } else if ref.mimeType.hasPrefix("image/") {
            sourceURL = files.fileURL
        } else {
            throw HomeRejection.invalid("no_thumbnail")
        }
        let target = files.fileURL.deletingLastPathComponent().appendingPathComponent("thumb-\(maxPixel).jpg")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        let data = try thumbnailJPEG(of: sourceURL, maxPixel: maxPixel)
        try Task.checkCancellation()
        try data.write(to: target, options: .atomic)
        return target
    }
}
