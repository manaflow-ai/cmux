import CryptoKit
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// cmux: thumbnails for the pictures an agent's table names by path or web address (the user,
/// 2026-11-04, msg 21749: before and after shots in a table showed "[before] [after]"). A cell's
/// `![alt](/abs/shot.png)`, `![alt](file:///abs/shot.png)` or `![alt](https://…/shot.png)` gets a
/// small picture in Home's media folder (the only folder ``HomeMarkdownImages`` draws from), made
/// once off the main thread; ``asset(_:)`` returns it once made and starts it otherwise, and
/// ``onReady`` names the source whose thumbnail arrived so its card draws again.
///
/// Only picture files: a local source must be a regular file with a picture extension, at most
/// ``maxBytes``; a web source must be `https`, answer 200 with at most ``maxBytes``, fetched
/// without cookies or a cache (`URLSessionConfiguration.ephemeral`). Attachment pictures
/// (`cmux-attachment:<hash>`) are not this type's: ``HomeMedia`` has them.
final class HomeTablePictures: Sendable {
    /// Downloads a web picture to a local file (tests pass a fake).
    typealias Fetch = @Sendable (URL) async throws -> URL

    /// The picture extensions a local source may have.
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    /// A larger source is not drawn (its alt text shows).
    static let maxBytes = 40 * 1024 * 1024
    /// A thumbnail's long side, in pixels: a 180 pt tall cell picture at 2x, with room for wide shots.
    static let maxPixel = 1280

    private struct State {
        var ready: [String: String] = [:]
        var loading: Set<String> = []
        var failed: Set<String> = []
        var onReady: @MainActor @Sendable (String) -> Void = { _ in }
    }

    private let directory: URL
    private let fetch: Fetch
    // Lock carve-out: `asset(_:)` is a synchronous lookup from the mapping (main thread and the loader
    // queue); short critical sections over three small collections, never held across work.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// - Parameter directory: where thumbnails are written (Home's media folder in the app).
    /// - Parameter fetch: downloads a web picture; the default uses an ephemeral `URLSession`.
    init(directory: URL = HomeMedia.directory, fetch: @escaping Fetch = HomeTablePictures.download) {
        self.directory = directory
        self.fetch = fetch
    }

    /// Called with a source once its thumbnail is ready (on the main actor).
    var onReady: @MainActor @Sendable (String) -> Void {
        get { state.withLock { $0.onReady } }
        set { state.withLock { $0.onReady = newValue } }
    }

    /// Whether `source` is a picture this type loads: an absolute path, a `file:` URL or an `https` URL.
    static func handles(_ source: String) -> Bool {
        source.hasPrefix("/") || source.hasPrefix("file://") || source.hasPrefix("https://")
    }

    /// The original a click opens: the local file, or the web address.
    static func original(_ source: String) -> URL? {
        if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
        guard let url = URL(string: source), url.isFileURL || url.scheme == "https" else { return nil }
        return url
    }

    /// The thumbnail's path for `source` once made; otherwise nil, and its making starts (once).
    func asset(_ source: String) -> String? {
        guard Self.handles(source) else { return nil }
        let start: Bool = state.withLock { s in
            if s.ready[source] != nil || s.loading.contains(source) || s.failed.contains(source) { return false }
            s.loading.insert(source)
            return true
        }
        if start { Task.detached(priority: .utility) { [self] in await self.make(source) } }
        return state.withLock { $0.ready[source] }
    }

    /// Makes `source`'s thumbnail now and returns its path (nil when it is not a picture it may draw).
    @discardableResult
    func prepare(_ source: String) async -> String? {
        if let ready = state.withLock({ $0.ready[source] }) { return ready }
        state.withLock { _ = $0.loading.insert(source) }
        await make(source)
        return state.withLock { $0.ready[source] }
    }

    private func make(_ source: String) async {
        let file = await thumbnail(source)
        let notify: (@MainActor @Sendable (String) -> Void)? = state.withLock { s in
            s.loading.remove(source)
            guard let file else { s.failed.insert(source); return nil }
            s.ready[source] = file
            return s.onReady
        }
        if let notify { await MainActor.run { notify(source) } }
    }

    private func thumbnail(_ source: String) async -> String? {
        guard let original = Self.original(source) else { return nil }
        let local: URL
        if original.isFileURL {
            guard Self.extensions.contains(original.pathExtension.lowercased()),
                  let values = try? original.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0, size <= Self.maxBytes else { return nil }
            local = original
        } else {
            guard let fetched = try? await fetch(original) else { return nil }
            local = fetched
        }
        // A download is a temporary file of its own: it goes once its thumbnail is made.
        defer { if !original.isFileURL { try? FileManager.default.removeItem(at: local) } }
        let name = "table-" + SHA256.hash(data: Data(source.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return Self.write(local, to: directory.appendingPathComponent(name).appendingPathExtension("png"))
    }

    /// Decodes at most ``maxPixel`` on the long side (never the whole picture in memory) and writes a PNG.
    private static func write(_ source: URL, to target: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(target as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? target.path : nil
    }

    /// The default ``Fetch``: an ephemeral `URLSession` (no cookies, no cache), https only, 200, at most ``maxBytes``.
    @Sendable static func download(_ url: URL) async throws -> URL {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (file, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes else {
            try? FileManager.default.removeItem(at: file)
            throw URLError(.badServerResponse)
        }
        return file
    }
}
