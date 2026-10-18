public import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Bringing a background in (cx-t2x.8, backgrounds plan phase 3): a file is checked before it is
/// copied, so the folder never lists a picture that will not decode or a movie macOS cannot play,
/// and a link downloads with a size cap and is judged by its bytes, not its name.
extension BackdropUserImages {
    /// Why a file or link cannot be a background; `code` is what the Settings page shows.
    public nonisolated struct ImportError: Error, Equatable, Sendable {
        public let code: String

        /// Not an https link.
        public static let notHTTPS = Self(code: "cmux.settings.backdrop.not_https")
        /// Bigger than ``maximumImageBytes`` or ``maximumVideoBytes``.
        public static let tooLarge = Self(code: "cmux.settings.backdrop.too_large")
        /// Neither a picture that decodes nor a movie macOS can play.
        public static let notMedia = Self(code: "cmux.settings.backdrop.not_media")
        /// The download failed.
        public static let downloadFailed = Self(code: "cmux.settings.backdrop.download_failed")
    }

    /// The largest picture a link may bring.
    public nonisolated static let maximumImageBytes: Int64 = 50 * 1024 * 1024
    /// The largest movie a link may bring.
    public nonisolated static let maximumVideoBytes: Int64 = 500 * 1024 * 1024

    /// Copies `source` into the folder after checking it decodes (a picture) or plays (a movie).
    public func adoptChecked(_ source: URL) async throws -> BackdropSelection {
        guard await Self.isUsable(source) else { throw ImportError.notMedia }
        let images = self
        // The copy runs off the main actor: a movie can be hundreds of megabytes.
        return try await Task.detached { try images.adopt(source) }.value
    }

    /// Whether `url` holds a picture that decodes or a movie with a picture macOS can play.
    public nonisolated static func isUsable(_ url: URL) async -> Bool {
        if AppleWallpapers.isVideo(url.path) {
            let asset = AVURLAsset(url: url)
            guard (try? await asset.load(.isPlayable)) == true else { return false }
            return !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceThumbnailMaxPixelSize: 64,
                                                               kCGImageSourceCreateThumbnailFromImageAlways: true] as CFDictionary) != nil
    }

    /// Downloads the picture or movie at `link` (https only) into a fresh temporary folder and
    /// returns the file, named for what its bytes are. The caller adopts it (``adoptChecked(_:)``)
    /// and removes its folder.
    public nonisolated static func download(_ link: URL, session: URLSession = .shared) async throws -> URL {
        guard link.scheme?.lowercased() == "https", link.host != nil else { throw ImportError.notHTTPS }
        let (file, mimeType) = try await fetch(link, session: session)
        do {
            let named = try named(file, link: link, mimeType: mimeType)
            let size = (try? named.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size <= (AppleWallpapers.isVideo(named.path) ? maximumVideoBytes : maximumImageBytes) else { throw ImportError.tooLarge }
            return named
        } catch {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            throw error
        }
    }

    /// The download, stopped once it passes ``maximumVideoBytes``, and the server's media type.
    private nonisolated static func fetch(_ link: URL, session: URLSession) async throws -> (URL, String?) {
        let watcher = DownloadCap(limit: maximumVideoBytes)
        let downloaded: URL, response: URLResponse
        do {
            (downloaded, response) = try await session.download(from: link, delegate: watcher)
        } catch {
            throw watcher.exceeded ? ImportError.tooLarge : ImportError.downloadFailed
        }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            try? FileManager.default.removeItem(at: downloaded)
            throw ImportError.downloadFailed
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-background-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("download")
        try FileManager.default.moveItem(at: downloaded, to: file)
        return (file, response.mimeType)
    }

    /// `file` renamed for its bytes: a picture's type from ImageIO, else the server's movie type,
    /// else the link's own extension when it names a movie. Anything else is not media.
    private nonisolated static func named(_ file: URL, link: URL, mimeType: String?) throws -> URL {
        let stem = link.deletingPathExtension().lastPathComponent
        let name = stem.isEmpty || stem == "/" ? "Background" : String(stem.prefix(80))
        var ext: String?
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source) as String? {
            ext = UTType(type)?.preferredFilenameExtension
        } else if let mime = mimeType, let type = UTType(mimeType: mime), type.conforms(to: .movie) {
            ext = type.preferredFilenameExtension
        } else if AppleWallpapers.videoExtensions.contains(link.pathExtension.lowercased()) {
            ext = link.pathExtension.lowercased()
        }
        guard let ext, extensions.contains(ext.lowercased()) else { throw ImportError.notMedia }
        let named = file.deletingLastPathComponent().appendingPathComponent("\(name).\(ext.lowercased())")
        try FileManager.default.moveItem(at: file, to: named)
        return named
    }

    /// Removes one of the folder's own images (never downloaded art or a file elsewhere).
    public func remove(_ selection: BackdropSelection, fileManager: FileManager = .default) throws {
        guard contains(selection), case .file(let path) = selection else { throw CocoaError(.fileNoSuchFile) }
        try fileManager.removeItem(atPath: path)
    }

    /// The bytes the folder's own images take, downloaded art left out.
    public func usage(fileManager: FileManager = .default) -> Int64 {
        list(fileManager: fileManager).reduce(into: Int64(0)) { total, selection in
            guard case .file(let path) = selection else { return }
            total += ((try? fileManager.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0
        }
    }
}

/// Cancels a download once it passes `limit` bytes, so a huge file never lands on disk whole.
private nonisolated final class DownloadCap: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    private let lock = NSLock()
    private var passed = false

    init(limit: Int64) { self.limit = limit }

    var exceeded: Bool { lock.withLock { passed } }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten > limit || totalBytesExpectedToWrite > limit else { return }
        lock.withLock { passed = true }
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
