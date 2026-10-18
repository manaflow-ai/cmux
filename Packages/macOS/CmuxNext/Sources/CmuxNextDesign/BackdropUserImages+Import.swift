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

    /// Downloads the picture or movie at `link` (https only, redirects included) into a fresh
    /// temporary folder and returns the file, named for what its bytes are. The caller adopts it
    /// (``adoptChecked(_:)``) and removes its folder. The download stops as soon as it passes the
    /// cap for what the server says it is (``maximumImageBytes`` for a picture, else
    /// ``maximumVideoBytes``), so a huge file never lands on disk whole.
    public nonisolated static func download(_ link: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> URL {
        guard isHTTPS(link) else { throw ImportError.notHTTPS }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-background-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("download")
            let mimeType = try await LinkDownload(file: file, configuration: configuration).run(link)
            let named = try named(file, link: link, mimeType: mimeType)
            let size = (try? named.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            guard size <= (AppleWallpapers.isVideo(named.path) ? maximumVideoBytes : maximumImageBytes) else { throw ImportError.tooLarge }
            return named
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    nonisolated static func isHTTPS(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false
    }

    /// The cap for a body the server calls `mimeType`.
    nonisolated static func cap(for mimeType: String?) -> Int64 {
        mimeType?.lowercased().hasPrefix("image/") == true ? maximumImageBytes : maximumVideoBytes
    }

    /// A file name from the link's last path component: its own name only (no folders, no
    /// leading dots, nothing the file system reads as a path), at most 80 characters.
    nonisolated static func safeStem(_ link: URL) -> String {
        let decoded = link.deletingPathExtension().lastPathComponent
        let cleaned = String(decoded.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 })
        let stem = String(cleaned.drop { $0 == "." || $0 == "-" || $0.isWhitespace }.prefix(80)).trimmingCharacters(in: .whitespaces)
        return stem.isEmpty ? "Background" : stem
    }

    /// `file` renamed for its bytes: a picture's type from ImageIO, else the server's movie type,
    /// else the link's own extension when it names a movie. Anything else is not media.
    private nonisolated static func named(_ file: URL, link: URL, mimeType: String?) throws -> URL {
        var ext: String?
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let type = CGImageSourceGetType(source) as String? {
            ext = UTType(type)?.preferredFilenameExtension
        } else if let mime = mimeType, let type = UTType(mimeType: mime), type.conforms(to: .movie) {
            ext = type.preferredFilenameExtension
        } else if AppleWallpapers.videoExtensions.contains(link.pathExtension.lowercased()) {
            ext = link.pathExtension.lowercased()
        }
        guard let ext, extensions.contains(ext.lowercased()) else { throw ImportError.notMedia }
        let named = file.deletingLastPathComponent().appendingPathComponent("\(safeStem(link)).\(ext.lowercased())")
        // Never outside the download's own folder, whatever the name.
        guard named.deletingLastPathComponent().standardizedFileURL == file.deletingLastPathComponent().standardizedFileURL else {
            throw ImportError.notMedia
        }
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

/// One link download into `file`: a data task whose delegate checks the declared length and the
/// running count against the cap for the declared type, refuses a redirect off https, and writes
/// the body as it arrives. Timeouts are a minute without data and ten minutes in all.
private nonisolated final class LinkDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let file: URL
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var cap = BackdropUserImages.maximumVideoBytes
    private var mimeType: String?
    private var refusal: BackdropUserImages.ImportError?
    private var continuation: CheckedContinuation<String?, any Error>?

    init(file: URL, configuration: URLSessionConfiguration) {
        self.file = file
        let configuration = configuration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        self.configuration = configuration
    }

    /// The server's media type once the body is on disk.
    func run(_ link: URL) async throws -> String? {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                session.dataTask(with: link).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func refuse(_ error: BackdropUserImages.ImportError) {
        lock.withLock { if refusal == nil { refusal = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard BackdropUserImages.isHTTPS(request.url) else {
            refuse(.notHTTPS)
            task.cancel()
            return completionHandler(nil)
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let cap = BackdropUserImages.cap(for: response.mimeType)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            refuse(.downloadFailed)
            return completionHandler(.cancel)
        }
        guard response.expectedContentLength <= cap else {
            refuse(.tooLarge)
            return completionHandler(.cancel)
        }
        let opened: FileHandle? = FileManager.default.createFile(atPath: file.path, contents: nil)
            ? try? FileHandle(forWritingTo: file) : nil
        lock.withLock {
            self.cap = cap
            mimeType = response.mimeType
            handle = opened
        }
        if opened == nil { refuse(.downloadFailed) }
        completionHandler(opened == nil ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (handle, over) = lock.withLock { () -> (FileHandle?, Bool) in
            written += Int64(data.count)
            return (self.handle, written > cap)
        }
        guard !over else {
            refuse(.tooLarge)
            return dataTask.cancel()
        }
        do { try handle?.write(contentsOf: data) } catch {
            refuse(.downloadFailed)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, refusal, mimeType, handle) = lock.withLock {
            let taken = (self.continuation, self.refusal, self.mimeType, self.handle)
            self.continuation = nil
            self.handle = nil
            return taken
        }
        try? handle?.close()
        if let refusal { continuation?.resume(throwing: refusal) } else if error != nil {
            continuation?.resume(throwing: BackdropUserImages.ImportError.downloadFailed)
        } else {
            continuation?.resume(returning: mimeType)
        }
    }
}
