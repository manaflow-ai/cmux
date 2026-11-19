import CmuxNextCompat
public import Foundation

/// The YouTube wallpapers the person has used, listed in the picker under Moving wallpapers
/// (``BackdropCatalog``): `YouTube.json` in the backgrounds folder, newest first, with each
/// video's title. A video is added the first time a window shows it, however it was chosen (the
/// picker, the CLI, a config file), and removed from the picker like one of the person's own
/// images. Living in the backgrounds folder, a change rebuilds the catalog through the folder
/// watch it already has (``BackdropCatalogStore``); a shuffle of that folder reads only pictures.
public nonisolated struct BackdropYouTubeLibrary: Sendable {
    /// The list's file.
    public let file: URL

    /// The file's name in the backgrounds folder.
    public static let fileName = "YouTube.json"

    /// The most videos kept: the oldest falls off.
    public static let limit = 100

    private struct Stored: Codable {
        var videos: [Video]
        struct Video: Codable {
            var id: String
            var title: String?
        }
    }

    /// The list in `folder` (the backgrounds folder).
    public init(folder: URL) {
        file = folder.appendingPathComponent(Self.fileName)
    }

    /// The app's list, in the backgrounds folder (``BackdropArtDownloads/defaultFolder``).
    public static var app: BackdropYouTubeLibrary? {
        BackdropArtDownloads.defaultFolder.map(BackdropYouTubeLibrary.init(folder:))
    }

    /// The videos, newest first.
    public func list() -> [BackdropYouTube] { items().map(\.video) }

    /// The videos, newest first, with YouTube's title when known.
    public func items() -> [(video: BackdropYouTube, title: String?)] {
        read().videos.compactMap { stored in
            BackdropYouTube(id: stored.id).map { ($0, BackdropYouTube.cleanTitle(stored.title)) }
        }
    }

    /// YouTube's title of a listed video, by video id.
    public func titles() -> [String: String] {
        let pairs = items().compactMap { item in item.title.map { (item.video.videoID, $0) } }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    /// Whether `video` is listed.
    public func contains(_ video: BackdropYouTube) -> Bool {
        read().videos.contains { $0.id == video.id }
    }

    /// Lists `video` first (moving it there when listed), with `title` when known. Writes only
    /// when something changed, so showing a listed video again touches no file.
    public func add(_ video: BackdropYouTube, title: String? = nil) throws {
        var stored = read()
        let known = stored.videos.first { $0.id == video.id }
        let entry = Stored.Video(id: video.id, title: title ?? known?.title)
        guard stored.videos.first?.id != video.id || known?.title != entry.title else { return }
        stored.videos.removeAll { $0.id == video.id }
        stored.videos.insert(entry, at: 0)
        stored.videos = Array(stored.videos.prefix(Self.limit))
        try write(stored)
    }

    /// Takes `video` off the list.
    public func remove(_ video: BackdropYouTube) throws {
        var stored = read()
        guard stored.videos.contains(where: { $0.id == video.id }) else { throw CocoaError(.fileNoSuchFile) }
        stored.videos.removeAll { $0.id == video.id }
        try write(stored)
    }

    private func read() -> Stored {
        guard let data = try? Data(blockingContentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored(videos: [])
        }
        return stored
    }

    /// Atomically, so a reader never sees half a list.
    private func write(_ stored: Stored) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stored)
        try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.blockingWrite(to: file, options: .atomic)
    }
}

/// A YouTube wallpaper's poster and title, fetched once each: the thumbnail from i.ytimg.com into
/// Caches (``BackdropYouTube/posterURL``), the title from YouTube's oEmbed into the library. The
/// video stream itself is never fetched or kept; only the embed plays it.
public actor BackdropYouTubeDownloads {
    /// The largest poster or oEmbed answer read.
    static let maximumBytes = 2 << 20

    private let library: BackdropYouTubeLibrary?
    private let fetch: @Sendable (URL) async throws -> Data
    private var posters: [String: Task<URL?, Never>] = [:]
    private var titles: [String: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - library: Where a shown video is listed with its title; nil lists none.
    ///   - fetch: Reads a URL's body (tests inject one).
    public init(library: BackdropYouTubeLibrary?, fetch: @escaping @Sendable (URL) async throws -> Data) {
        self.library = library
        self.fetch = fetch
    }

    /// The poster of `video`, downloading it first if needed; nil when that fails.
    public func poster(for video: BackdropYouTube) async -> URL? {
        let file = video.posterURL
        if FileManager.checked.fileExists(atPath: file.path) { return file }
        if let load = posters[video.videoID] { return await load.value }
        guard let remote = video.posterRemoteURL else { return nil }
        let fetch = fetch
        // task-owner: one poster download per video id, shared by concurrent callers and cleared when done
        let load = Task<URL?, Never> {
            guard let data = try? await fetch(remote), data.count <= Self.maximumBytes,
                  Self.write(data, to: file) else { return nil }
            return file
        }
        posters[video.videoID] = load
        let result = await load.value
        posters[video.videoID] = nil
        return result
    }

    /// Lists `video` in the library, with YouTube's title (oEmbed, read once while unknown).
    public func shown(_ video: BackdropYouTube) async {
        if let load = titles[video.id] { return await load.value }
        let fetch = fetch, library = library
        // task-owner: one oEmbed read and list write per video, shared by concurrent callers and cleared when done
        let load = Task<Void, Never> {
            guard let library else { return }
            var title = library.titles()[video.videoID]
            if title == nil, let url = video.oEmbedURL, let data = try? await fetch(url), data.count <= Self.maximumBytes,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                title = BackdropYouTube.cleanTitle(object["title"] as? String)
            }
            try? library.add(video, title: title)
        }
        titles[video.id] = load
        await load.value
        titles[video.id] = nil
    }

    /// Atomically, so a reader never sees half a poster (the download runs off the main actor).
    private static func write(_ data: Data, to file: URL) -> Bool {
        do {
            try FileManager.checked.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.blockingWrite(to: file, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
