public import Foundation

/// Fetches, verifies and caches signed release notes (R114 changelog).
/// Notes live next to the build's appcast: `<feed folder>/notes/<build>.json`
/// and `.sig`. Only notes whose signature verifies are cached or returned;
/// a build's notes come from the cache once verified, the index and
/// announcements from the network first; offline, the cache answers.
nonisolated public struct ReleaseNotesStore: Sendable {
    public let notesBase: URL
    public let cache: URL
    public let publicKey: String
    private let fetcher: any AppcastFetching

    /// - Parameter feedURL: the build's appcast URL; notes sit in its folder.
    public init?(feedURL: String, cache: URL, publicKey: String = ContentSignature.publicKey,
                 fetcher: any AppcastFetching = URLSessionAppcastFetcher()) {
        guard let feed = URL(string: feedURL), feed.scheme == "https" || feed.host == "127.0.0.1" || feed.host == "localhost"
        else { return nil }
        notesBase = feed.deletingLastPathComponent().appending(path: "notes", directoryHint: .isDirectory)
        self.cache = cache
        self.publicKey = publicKey
        self.fetcher = fetcher
    }

    /// The verified notes of `build`: cached once verified (a build's notes never
    /// change), else fetched.
    @concurrent
    public func notes(for build: String) async -> ReleaseNotes? {
        guard Self.isSafeName(build), let data = await verified("\(build).json", cacheFirst: true),
              var notes = try? JSONDecoder().decode(ReleaseNotes.self, from: data), notes.build == build else { return nil }
        // Older notes carry only commit subjects: readers (the changelog page) get titles with PRs.
        notes.items = notes.changeItems
        return notes
    }

    /// The verified index of recent builds (newest first), fresh or cached.
    @concurrent
    public func index() async -> [ReleaseNotesIndexEntry] {
        struct Index: Decodable { var builds: [ReleaseNotesIndexEntry] }
        guard let data = await verified("index.json"), let index = try? JSONDecoder().decode(Index.self, from: data) else { return [] }
        return index.builds
    }

    /// The verified announcement cards (`notes/announcements.json`), fresh or cached.
    @concurrent
    public func announcements() async -> [Announcement] {
        struct Feed: Decodable { var items: [Announcement] }
        guard let data = await verified("announcements.json"), let feed = try? JSONDecoder().decode(Feed.self, from: data) else { return [] }
        return feed.items
    }

    /// The verified kill-switch document (`notes/flags.json`, KillSwitchDocument), fresh or cached;
    /// nil when neither verifies, which turns nothing off.
    @concurrent
    public func flags() async -> KillSwitchDocument? {
        guard let data = await verified("flags.json") else { return nil }
        return KillSwitchDocument(data: data)
    }

    /// The file and its signature, fetched together from the network (cached
    /// once verified), else the cached pair, verified again. `cacheFirst`
    /// (a build's notes, which never change) answers from the verified cache
    /// and fetches only when it misses, so What's New opens inside its paint hold.
    @concurrent
    private func verified(_ name: String, cacheFirst: Bool = false) async -> Data? {
        if cacheFirst, let data = cached(name) { return data }
        async let fetchedData = try? fetcher.fetch(notesBase.appending(path: name))
        async let fetchedSignature = try? fetcher.fetch(notesBase.appending(path: name + ".sig"))
        if let data = await fetchedData, let sig = await fetchedSignature,
           let text = String(data: sig, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           ContentSignature.verify(data, signature: text, publicKey: publicKey) {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: cache.appending(path: name), options: .atomic)
            try? sig.write(to: cache.appending(path: name + ".sig"), options: .atomic)
            return data
        }
        return cacheFirst ? nil : cached(name)
    }

    /// The cached pair, when its signature still verifies.
    private func cached(_ name: String) -> Data? {
        // concurrency-allow: called from @concurrent verified(_:), never on the main thread; small cached files.
        guard let data = try? Data(contentsOf: cache.appending(path: name)),
              // concurrency-allow: called from @concurrent verified(_:), never on the main thread; small cached files.
              let sig = try? String(contentsOf: cache.appending(path: name + ".sig"), encoding: .utf8),
              ContentSignature.verify(data, signature: sig.trimmingCharacters(in: .whitespacesAndNewlines), publicKey: publicKey)
        else { return nil }
        return data
    }

    /// The checked media of these notes (cx-urd.61.1), cached beside them, fetched with a short
    /// deadline; `bundledDirectories` hold the app's reviewed What's New media.
    public func media(bundledDirectories: [URL]) -> ReleaseMediaStore {
        ReleaseMediaStore(cache: cache.appending(path: "media", directoryHint: .isDirectory), bundledDirectories: bundledDirectories)
    }

    /// Build numbers only: never a path.
    static func isSafeName(_ build: String) -> Bool {
        !build.isEmpty && build.allSatisfy { $0.isNumber || $0 == "." }
    }
}

/// One build in `notes/index.json`.
nonisolated public struct ReleaseNotesIndexEntry: Codable, Equatable, Sendable {
    public var build: String
    public var shortVersion: String
    public var date: String
    public var highlights: Int
    /// The commit the build was cut from (`head`; older indexes lack it).
    public var head: String?

    public init(build: String, shortVersion: String, date: String, highlights: Int, head: String? = nil) {
        self.build = build
        self.shortVersion = shortVersion
        self.date = date
        self.highlights = highlights
        self.head = head
    }
}
