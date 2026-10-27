#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Hashing, the blob cache layout and the prepare pipeline for attachments.
/// The media readers it calls (image size, preview, poster, conversion,
/// location removal) are per platform, as Chromium keeps `*_mac.mm` and
/// `*_linux.cc` behind one interface: ImageIO and AVFoundation in
/// AttachmentMedia+ImageIO.swift, and AttachmentMedia+NoImageIO.swift where
/// those frameworks do not exist. Every function here is nonisolated and
/// async, so callers on the main actor run the work on the global executor.
enum AttachmentMedia {
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

    // MARK: Video and audio

    /// What ``inspectMovie(_:posterMaxPixel:)`` reads: duration, display
    /// size and the first frame as a JPEG poster.
    struct Movie {
        var width: Int?
        var height: Int?
        var durationMs: Int?
        var posterJPEG: Data?
    }

    // MARK: Prepare

    /// The owner's mime type for a file extension: the allow list's own
    /// table first, then the OS's UTType.
    static func mimeType(forExtension fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        if let known = HomeAttachmentPolicy.extensionTypes[ext] { return known }
        return HomeAttachmentPolicy.canonicalMimeType(mimeType(for: UTType(filenameExtension: ext)))
    }

    /// `text/plain` or the generic type for a file with no listed type, from
    /// its first ``HomeAttachmentPolicy/sniffBytes`` bytes.
    static func sniffedMimeType(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: HomeAttachmentPolicy.sniffBytes) ?? Data()
        let complete: Bool
        if prefix.count < HomeAttachmentPolicy.sniffBytes {
            complete = true
        } else {
            complete = try (handle.read(upToCount: 1) ?? Data()).isEmpty
        }
        return HomeAttachmentPolicy.sniffedMimeType(prefix, complete: complete)
    }

    /// Checks the policy, then copies the bytes into the cache and fills the
    /// ref. Opens a security-scoped URL (the iOS file importer's) for the
    /// copy. Removes location metadata unless `keepLocation`. `name`
    /// defaults to the file's own name. `@concurrent`: hashing 100 MB never
    /// runs on the caller's actor.
    @concurrent
    static func prepare(fileURL: URL, root: URL, name: String? = nil, keepLocation: Bool = false) async throws -> LocalAttachment {
        #if canImport(Darwin)
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        #endif
        let name = HomeAttachmentPolicy.sendableName(name ?? fileURL.lastPathComponent)
        if HomeAttachmentPolicy.isFolder(fileURL) { throw HomeAttachmentError.folder(name: name) }
        let mime: String
        switch HomeAttachmentPolicy.decision(forFileExtension: fileURL.pathExtension) {
        case .send(let owned):
            mime = owned
        case .convert:
            // An image ImageIO cannot read goes as its bytes (text or a generic file).
            guard let converted = try convertedImage(fileURL: fileURL) else {
                mime = try sniffedMimeType(ofFile: fileURL)
                break
            }
            let base = (name as NSString).deletingPathExtension
            return try await prepare(data: converted.data, typeIdentifier: converted.type.identifier, root: root,
                                     name: "\(base).\(converted.fileExtension)", keepLocation: keepLocation)
        case .sniff:
            mime = try sniffedMimeType(ofFile: fileURL)
        }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try HomeAttachmentPolicy.check(mimeType: mime, byteCount: size, name: name)
        if !keepLocation {
            if let clean = try imageWithoutLocation(fileURL: fileURL, mimeType: mime, name: name) {
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
        switch type.map(HomeAttachmentPolicy.decision(for:)) ?? .sniff {
        case .send(let owned):
            mime = owned
        case .convert:
            if let converted = try convertedImage(data: data) {
                return try await prepare(data: converted.data, typeIdentifier: converted.type.identifier, root: root,
                                         name: name ?? "attachment.\(converted.fileExtension)", keepLocation: keepLocation)
            }
            fallthrough // bytes ImageIO cannot read go as text or a generic file
        case .sniff:
            let prefix = data.prefix(HomeAttachmentPolicy.sniffBytes)
            mime = HomeAttachmentPolicy.sniffedMimeType(prefix, complete: prefix.count == data.count)
        }
        let name = HomeAttachmentPolicy.sendableName(name ?? (fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"))
        try HomeAttachmentPolicy.check(mimeType: mime, byteCount: data.count, name: name)
        if !keepLocation {
            if let clean = try imageWithoutLocation(data: data, mimeType: mime, name: name) {
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

    /// A WebP without its `EXIF` and `XMP ` chunks, the VP8X flags for them
    /// cleared and every other chunk (frames, animation, ICC profile) kept
    /// byte for byte. Only the bytes the RIFF size covers are read: bytes
    /// after them are dropped, never sent. Nil when the bytes are not a
    /// well-formed WebP RIFF (a RIFF size below 4, or a chunk that runs
    /// past the RIFF data).
    static func webPWithoutMetadataChunks(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        func le32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        func le32Bytes(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(value >> (8 * $0) & 0xff) } }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WEBP".utf8) else {
            return nil
        }
        let riffSize = le32(4)
        guard riffSize >= 4 else { return nil }
        // A truncated file ends early; a chunk that runs past it is refused below.
        let limit = min(bytes.count, 8 + riffSize)
        var body = Array("WEBP".utf8)
        var index = 12
        while index < limit {
            guard index + 8 <= limit else { return nil }
            let size = le32(index + 4)
            guard size >= 0, index + 8 + size <= limit else { return nil }
            let end = min(limit, index + 8 + size + (size & 1))
            let tag = bytes[index..<(index + 4)]
            defer { index = end }
            if tag.elementsEqual("EXIF".utf8) || tag.elementsEqual("XMP ".utf8) { continue }
            var chunk = Array(bytes[index..<end])
            if tag.elementsEqual("VP8X".utf8), chunk.count > 8 { chunk[8] &= ~UInt8(0x0C) } // EXIF and XMP flags
            body += chunk
        }
        return Data(Array("RIFF".utf8) + le32Bytes(body.count) + body)
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
            if mimeType.hasPrefix("video/"), let posterData = movie.posterJPEG,
               posterData.count <= HomeAttachmentPolicy.posterMaxBytes {
                let (posterHash, url) = try ingest(data: posterData, fileExtension: "jpg", root: root)
                ref.poster = AttachmentPoster(hash: posterHash, mimeType: "image/jpeg", byteCount: posterData.count)
                posterURL = url
            }
        }
        return LocalAttachment(ref: HomeAttachmentPolicy.normalized(ref), fileURL: cached, posterURL: posterURL,
                               previewURL: previewURL)
    }

    /// A cached thumbnail next to the blob (`thumb-v2-<maxPixel>.jpg`, or
    /// `.png` for a transparent image). Builds before v2 drew transparent
    /// images on black into `thumb-<maxPixel>.jpg`: such a file is deleted,
    /// never reused.
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
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("thumb-\(maxPixel).\(fileExtension)"))
            let cached = directory.appendingPathComponent("thumb-v2-\(maxPixel).\(fileExtension)")
            if FileManager.default.fileExists(atPath: cached.path) { return cached }
        }
        let thumb = try thumbnail(of: sourceURL, maxPixel: maxPixel)
        try Task.checkCancellation()
        let target = directory.appendingPathComponent("thumb-v2-\(maxPixel).\(thumb.fileExtension)")
        try thumb.data.write(to: target, options: .atomic)
        return target
    }
}
