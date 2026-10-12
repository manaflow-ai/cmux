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
        for result in found where results[result.key] == nil {
            results[result.key] = result
            order.append(result.key)
        }
        while order.count > Self.keep { results[order.removeFirst()] = nil }
        return ["results": .array(found.map { result in
            ["key": .string(result.key), "title": .string(result.title), "artist": .string(result.artist),
             "date": .string(result.date), "source": .string(result.source.name), "page": .string(result.page.absoluteString)]
        })]
    }

    /// `cmux-page://cmux.settings/museum/<key>`: the result's thumbnail.
    func thumbnail(key: String) async -> Data? {
        if let data = thumbnails[key] { return data }
        guard let result = results[key], let data = await search.image(result.thumbnail, of: result) else { return nil }
        thumbnails[key] = data
        return data
    }

    /// Downloads the result's image into a temporary file named "Title — Artist" for
    /// ``BackdropUserImages/adopt(_:fileManager:)`` to copy; nil when that fails.
    func download(key: String) async -> URL? {
        guard let result = results[key], let data = await search.image(result.image, of: result),
              data.count <= Self.downloadLimit else { return nil }
        let name = [result.title, result.artist].filter { !$0.isEmpty }.joined(separator: " — ")
        let safe = String(name.map { "/:\\".contains($0) ? "-" : $0 }.prefix(120))
        let ext = ["jpg", "jpeg", "png", "tif", "tiff"].contains(result.image.pathExtension.lowercased())
            ? result.image.pathExtension.lowercased() : "jpg"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-art-\(UUID().uuidString)", isDirectory: true)
        let file = folder.appendingPathComponent("\(safe.isEmpty ? result.key : safe).\(ext)")
        return await Task.detached { Self.write(data, to: file) ? file : nil }.value
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
