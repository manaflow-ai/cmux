public import Foundation

/// Fetches, verifies and caches signed release notes (R114 changelog).
/// Notes live next to the build's appcast: `<feed folder>/notes/<build>.json`
/// and `.sig`. Only notes whose signature verifies are cached or returned;
/// offline, the cache answers.
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

    /// The verified notes of `build`: fresh when the network answers, else cached.
    @concurrent
    public func notes(for build: String) async -> ReleaseNotes? {
        guard Self.isSafeName(build), let data = await verified("\(build).json"),
              let notes = try? JSONDecoder().decode(ReleaseNotes.self, from: data), notes.build == build else { return nil }
        return notes
    }

    /// The verified index of recent builds (newest first), fresh or cached.
    @concurrent
    public func index() async -> [ReleaseNotesIndexEntry] {
        struct Index: Decodable { var builds: [ReleaseNotesIndexEntry] }
        guard let data = await verified("index.json"), let index = try? JSONDecoder().decode(Index.self, from: data) else { return [] }
        return index.builds
    }

    /// The file and its signature from the network (cached once verified),
    /// else the cached pair, verified again.
    @concurrent
    private func verified(_ name: String) async -> Data? {
        let file = notesBase.appending(path: name), signature = notesBase.appending(path: name + ".sig")
        if let data = try? await fetcher.fetch(file), let sig = try? await fetcher.fetch(signature),
           let text = String(data: sig, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           ContentSignature.verify(data, signature: text, publicKey: publicKey) {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? data.write(to: cache.appending(path: name), options: .atomic)
            try? sig.write(to: cache.appending(path: name + ".sig"), options: .atomic)
            return data
        }
        // concurrency-allow: @concurrent, never on the main thread; small cached files.
        guard let data = try? Data(contentsOf: cache.appending(path: name)),
              // concurrency-allow: @concurrent, never on the main thread; small cached files.
              let sig = try? String(contentsOf: cache.appending(path: name + ".sig"), encoding: .utf8),
              ContentSignature.verify(data, signature: sig.trimmingCharacters(in: .whitespacesAndNewlines), publicKey: publicKey)
        else { return nil }
        return data
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
}
