import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// Browse more art (cx-t2x.8) for one Settings page: the latest museum results by key, so the page
/// names a work by key and cmux fetches only that work's own images (``MuseumArtSearch``).
///
/// Registered (`memory`), its grid thumbnails are one lossless memory consumer: a dropped thumbnail is
/// fetched again when the page asks for it. The limit scales how many thumbnails it keeps (at most
/// ``keep``, one per kept result); the results themselves are a few strings each and stay, so the page
/// can still name every work it shows.
@MainActor
final class MuseumArtSession {
    static let thumbnailPrefix = "museum"
    /// The most results (and so thumbnails) one page keeps.
    static let keep = 240
    /// Larger downloads are refused (a museum's "print" size is a few megabytes).
    private static let downloadLimit = 60 * 1024 * 1024
    /// A grid thumbnail is a few hundred kilobytes; a bigger answer is not kept.
    private static let thumbnailLimit = 4 * 1024 * 1024

    private let search: MuseumArtSearch
    private var results: [String: MuseumArtResult] = [:]
    /// Result keys, oldest answer first (at most ``keep``).
    private var order: [String] = []
    private var thumbnails: [String: Data] = [:]
    /// The bytes of ``thumbnails``, kept on every insert and removal (the memory report).
    private var thumbnailBytes = 0
    /// How many thumbnails it keeps: ``keep`` scaled by the memory coordinator's limit.
    private var thumbnailCap = MuseumArtSession.keep
    private var memoryRegistration: MemoryConsumerRegistration?

    /// - Parameters:
    ///   - search: The museum collections (tests inject recorded answers).
    ///   - memory: The memory coordinator the thumbnails register with; nil keeps them unregistered.
    init(search: MuseumArtSearch = .live, memory: (any MemoryConsumerRegistry)? = nil) {
        self.search = search
        if let memory {
            memoryRegistration = MemoryConsumerRegistration(
                name: Self.memoryConsumerName, traits: Self.memoryTraits, consumer: self, registry: memory)
        }
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
            removeThumbnail(key)
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
        removeThumbnail(key)
        thumbnails[key] = data
        thumbnailBytes += data.count
        dropOldestThumbnails(to: thumbnailCap, within: nil)
        return data
    }

    private func removeThumbnail(_ key: String) {
        guard let data = thumbnails.removeValue(forKey: key) else { return }
        thumbnailBytes -= data.count
    }

    /// Drops the thumbnails of the oldest answers until at most `limit` stay, or `slice` is spent.
    ///
    /// - Returns: Whether at most `limit` stay.
    @discardableResult
    private func dropOldestThumbnails(to limit: Int, within slice: MemoryReleaseSlice?) -> Bool {
        // `order` holds every key with a thumbnail (both go together), oldest answer first: one pass.
        for key in order where thumbnails.count > limit {
            if slice?.isExpired == true { return false }
            removeThumbnail(key)
        }
        return thumbnails.count <= limit
    }

    /// Downloads the result's image into a temporary file named "Title — Artist" for
    /// ``BackdropUserImages/adopt(_:)`` to copy; nil when that fails.
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

/// The grid thumbnails as one lossless consumer (Chrome's consumer contract,
/// base/memory_coordinator/memory_consumer.h): a new limit only lowers how many the next fetch keeps;
/// ``releaseMemory(within:)`` drops the oldest answers' thumbnails down to it.
extension MuseumArtSession: MemoryConsumer {
    /// Up to ``keep`` thumbnails of a few hundred kilobytes (1 to 50 MB); dropping one touches only memory,
    /// and fetching it again is a network read, so only critical pressure acts.
    static let memoryTraits = MemoryConsumerTraits(
        estimatedUsage: .medium, dataAccess: .none, retention: .lossless, recreateCost: .expensive,
        releaseCPUCost: .low, isStateful: true, supportsMemoryLimit: true)

    /// The consumer's name in the memory report.
    static let memoryConsumerName = "museum-art-thumbnails"

    func updateMemoryLimit(_ limit: MemoryLimit) {
        thumbnailCap = limit.scale(Self.keep)
    }

    func releaseMemory(within slice: MemoryReleaseSlice) -> MemoryReleaseProgress {
        updateMemoryLimit(slice.limit)
        return dropOldestThumbnails(to: thumbnailCap, within: slice) ? .done : .more
    }

    var memoryUsage: MemoryUsage? {
        MemoryUsage(footprintBytes: thumbnailBytes, entries: thumbnails.count)
    }
}
