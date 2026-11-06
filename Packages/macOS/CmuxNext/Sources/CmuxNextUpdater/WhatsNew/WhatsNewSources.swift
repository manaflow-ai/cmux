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
    /// its highlights, else the short summary (nil without any user-facing
    /// lines). Summary lines keep a signed nightly build discoverable when
    /// no highlight file was written for its release range.
    static func document(from notes: ReleaseNotes) -> WhatsNewDocument? {
        if var document = notes.whatsNew, document.schemaVersion == 1, document.version == notes.shortVersion {
            document.origin = .feed
            return document.entries.isEmpty ? nil : document
        }
        guard WhatsNewVersion(notes.shortVersion) != nil else { return nil }

        let entries: [WhatsNewDocument.Entry]
        if !notes.highlights.isEmpty {
            entries = notes.highlights.compactMap { highlight in
                let title = highlight.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return WhatsNewDocument.Entry(
                    id: highlight.id,
                    category: category(for: highlight.category),
                    title: WhatsNewText(stringLiteral: title),
                    summary: WhatsNewText(stringLiteral: highlight.body),
                    tryIt: highlight.action.map { WhatsNewDocument.TryIt(action: $0.id) }
                )
            }
        } else {
            entries = (notes.summary ?? []).enumerated().compactMap { index, line in
                let title = line.title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                let titleText = WhatsNewText(stringLiteral: title)
                let description = line.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                let summaryText = WhatsNewText(stringLiteral: description?.isEmpty == false ? description ?? title : title)
                return WhatsNewDocument.Entry(id: "summary-\(index)", category: category(for: line.group),
                                              title: titleText, summary: summaryText)
            }
        }
        guard let headline = entries.first?.title else { return nil }
        return WhatsNewDocument(version: notes.shortVersion, channel: .nightly, date: notes.date,
                                headline: headline, entries: entries, origin: .feed)
    }

    /// Release notes use "changed" for the short changelog while What's New
    /// uses "improved"; the latter is the closest user-facing category.
    private static func category(for value: String?) -> WhatsNewDocument.Category {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fixed": return .fixed
        case "improved", "changed": return .improved
        case "security": return .security
        default: return .new
        }
    }
}
