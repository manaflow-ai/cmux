import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// Browse more art (cx-t2x.8) for one Settings page: the latest museum results by key, so the page
/// names a work by key and cmux fetches only that work's own images (``MuseumArtSearch``).
@MainActor
final class MuseumArtSession {
    static let thumbnailPrefix = "museum"
    private static let keep = 240
    /// Larger downloads are refused (a museum's "print" size is a few megabytes).
    private static let downloadLimit = 60 * 1024 * 1024
    /// A grid thumbnail is a few hundred kilobytes; a bigger answer is not kept.
    private static let thumbnailLimit = 4 * 1024 * 1024

    private let search: MuseumArtSearch
    private var results: [String: MuseumArtResult] = [:]
    private var order: [String] = []
    private var thumbnails: [String: Data] = [:]

    init(search: MuseumArtSearch = .live) {
        self.search = search
    }

    /// `cmux.settings.art.search`: the works matching `query`, newest answer kept for later reads.
    func find(_ query: String) async -> JSONValue {
        let found = await search.search(query)
        // The latest answer moves to the end, so evicting the oldest never drops what the page shows.
        let keys = Set(found.map(\.key))
        order.removeAll { keys.contains($0) }
        for result in found {
            results[result.key] = result
            order.append(result.key)
        }
        while order.count > Self.keep {
            let key = order.removeFirst()
            results[key] = nil
            thumbnails[key] = nil
        }
        return ["results": .array(found.map { result in
            ["key": .string(result.key), "title": .string(result.title), "artist": .string(result.artist),
             "date": .string(result.date), "source": .string(result.source.name), "page": .string(result.page.absoluteString)]
        })]
    }

    /// `cmux-page://cmux.settings/museum/<key>`: the result's thumbnail.
    func thumbnail(key: String) async -> Data? {
        if let data = thumbnails[key] { return data }
        guard let result = results[key], let data = await search.image(result.thumbnail, of: result),
              data.count <= Self.thumbnailLimit, results[key] != nil else { return nil }
        thumbnails[key] = data
        return data
    }

    /// Downloads the result's image into a temporary file named "Title — Artist" for
    /// ``BackdropUserImages/adopt(_:fileManager:)`` to copy; nil when that fails.
    func download(key: String) async -> URL? {
        guard let result = results[key], let data = await search.image(result.image, of: result),
              data.count <= Self.downloadLimit else { return nil }
        let name = [result.title, result.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        let safe = Self.fileName(name)
        let ext = ["jpg", "jpeg", "png", "tif", "tiff"].contains(result.image.pathExtension.lowercased())
            ? result.image.pathExtension.lowercased() : "jpg"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-art-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("\(safe.isEmpty ? result.key : safe).\(ext)")
        return await Task.detached { Self.write(data, to: file) ? file : nil }.value
    }

    /// `name` as a visible file name: no path separators, control characters or leading dots,
    /// and at most 200 bytes so the extension and a " 2" suffix still fit the 255-byte limit.
    static func fileName(_ name: String) -> String {
        var safe = String(name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 })
        safe = safe.filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        while safe.hasPrefix(".") || safe.hasPrefix(" ") { safe.removeFirst() }
        while safe.utf8.count > 200 { safe.removeLast() }
        return safe
    }

    private nonisolated static func write(_ data: Data, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            return true
        } catch {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            return false
        }
    }
}
