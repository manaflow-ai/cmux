public import Foundation

/// Where What's New documents come from. The App combines the bundled
/// files (reviewed with the app, offline) and, for builds whose feed
/// publishes signed notes, the nightly digests in those notes.
nonisolated public protocol WhatsNewSource: Sendable {
    /// Documents for versions after `after` (nil: every version) up to and
    /// including `through`.
    func documents(after: WhatsNewVersion?, through: WhatsNewVersion) async -> [WhatsNewDocument]
    /// Whether a read costs network requests: such a source is asked only
    /// for the unseen range (or the newest few when nothing is unseen).
    var readsNetwork: Bool { get }
}

nonisolated extension WhatsNewSource {
    public var readsNetwork: Bool { false }
}

/// The documents bundled in the app: `<directory>/index.json`
/// (`{"versions": ["0.66.0", ...]}`) and `<directory>/<version>.json`, copied
/// from the repository's `whats-new/` by `scripts/whats-new/sync-app-bundle.sh`.
nonisolated public struct BundledWhatsNewSource: WhatsNewSource {
    public let directory: URL?

    public init(directory: URL?) {
        self.directory = directory
    }

    /// The app's own copy (`Resources/WhatsNew` in this module).
    public static var app: BundledWhatsNewSource {
        BundledWhatsNewSource(directory: Bundle.module.url(forResource: "WhatsNew", withExtension: nil))
    }

    struct Index: Decodable {
        var versions: [String]
    }

    /// Where a bundled media path resolves (`media/<version>/<file>`).
    public func mediaURL(_ path: String) -> URL? {
        guard WhatsNewDocument.Media.isSafe(path), let directory else { return nil }
        return directory.appending(path: path)
    }

    public func documents(after: WhatsNewVersion?, through: WhatsNewVersion) async -> [WhatsNewDocument] {
        await read(after: after, through: through)
    }

    @concurrent
    private func read(after: WhatsNewVersion?, through: WhatsNewVersion) async -> [WhatsNewDocument] {
        // concurrency-allow: @concurrent, never on the main thread; small bundled files.
        guard let directory, let data = try? Data(contentsOf: directory.appending(path: "index.json")),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return [] }
        return index.versions.compactMap { text -> WhatsNewDocument? in
            guard let version = WhatsNewVersion(text), version <= through, after.map({ $0 < version }) ?? true,
                  // concurrency-allow: @concurrent, never on the main thread; small bundled files.
                  let data = try? Data(contentsOf: directory.appending(path: "\(version.description).json")) else { return nil }
            return WhatsNewDocument.decode(data, origin: .bundled).flatMap { $0.version == version.description ? $0 : nil }
        }
    }
}

/// The nightly digests in the build feed's signed release notes
/// (`notes/<build>.json`, key `whatsNew`; scripts/cmux-next/release-notes.py).
/// Notes without a digest but with highlights read as a digest of them.
/// At most `limit` missed builds are fetched, and `recentLimit` builds
/// when asked for every version (nothing unseen: the page's recent notes).
nonisolated public struct FeedWhatsNewSource: WhatsNewSource {
    public var readsNetwork: Bool { true }
    let recentLimit = 3
    let index: @Sendable () async -> [ReleaseNotesIndexEntry]
    let notes: @Sendable (String) async -> ReleaseNotes?
    let limit: Int

    public init(index: @escaping @Sendable () async -> [ReleaseNotesIndexEntry],
                notes: @escaping @Sendable (String) async -> ReleaseNotes?, limit: Int = 10) {
        self.index = index
        self.notes = notes
        self.limit = limit
    }

    public init(store: ReleaseNotesStore, limit: Int = 10) {
        self.init(index: { await store.index() }, notes: { await store.notes(for: $0) }, limit: limit)
    }

    public func documents(after: WhatsNewVersion?, through: WhatsNewVersion) async -> [WhatsNewDocument] {
        let builds = await index().filter { entry in
            guard let version = WhatsNewVersion(entry.shortVersion) else { return false }
            return version <= through && (after.map { $0 < version } ?? true)
        }
        var documents: [WhatsNewDocument] = []
        for entry in builds.prefix(after == nil ? min(limit, recentLimit) : limit) {
            guard let notes = await notes(entry.build), let document = Self.document(from: notes) else { continue }
            documents.append(document)
        }
        return documents
    }

    /// The digest of `notes`: its embedded document, else one built from
    /// its highlights (nil without either).
    static func document(from notes: ReleaseNotes) -> WhatsNewDocument? {
        if var document = notes.whatsNew, document.schemaVersion == 1, document.version == notes.shortVersion {
            document.origin = .feed
            return document.entries.isEmpty ? nil : document
        }
        guard !notes.highlights.isEmpty, WhatsNewVersion(notes.shortVersion) != nil else { return nil }
        let entries = notes.highlights.map { highlight in
            WhatsNewDocument.Entry(id: highlight.id, category: .new, title: WhatsNewText(stringLiteral: highlight.title),
                                   summary: WhatsNewText(stringLiteral: highlight.body),
                                   tryIt: highlight.action.map { WhatsNewDocument.TryIt(action: $0.id) })
        }
        return WhatsNewDocument(version: notes.shortVersion, channel: .nightly, date: notes.date,
                                headline: WhatsNewText(stringLiteral: notes.highlights[0].title), entries: entries, origin: .feed)
    }
}
