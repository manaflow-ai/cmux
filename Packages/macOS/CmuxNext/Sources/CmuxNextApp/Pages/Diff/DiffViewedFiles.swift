import CmuxNextSettings
import Foundation

/// The diff page's "Viewed" marks (GitHub "Files changed" parity), kept by
/// the host next to the recents (`diff-viewed.json`, coordinator decision
/// PAGE-PREFS): per scope (`{repoRoot, source}`, the page's `viewedScopeFor`:
/// the repository and its source kind with the base ref), the files marked
/// viewed with the patch fingerprint they had then, so a later change of the
/// file shows as "changed since viewed". At most ``scopeLimit`` scopes (the
/// least recently changed go first) and ``fileLimit`` files per scope. Reads
/// and writes run off the main actor, writes in order.
final class DiffViewedFiles {
    static let fileName = "diff-viewed.json"
    static let scopeLimit = 200
    static let fileLimit = 5000

    nonisolated struct Entry: Codable, Sendable, Equatable {
        var path: String
        var fingerprint: String
    }

    nonisolated struct Scope: Codable, Sendable, Equatable {
        var key: String
        var changedAt: Double
        var files: [Entry]
    }

    let url: URL
    private var scopes: [Scope]?
    private var loading: Task<[Scope], Never>?
    private var saving: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    static func standardURL(recents: URL) -> URL {
        recents.deletingLastPathComponent().appending(path: fileName)
    }

    /// `repoRoot` and `source` as one key.
    static func key(repoRoot: String, source: String) -> String { repoRoot + "\n" + source }

    func list(_ key: String) async -> [Entry] {
        await load().first { $0.key == key }?.files ?? []
    }

    func set(_ entry: Entry, in key: String, at date: Date = Date()) async {
        await change(key, at: date) { files in
            files.removeAll { $0.path == entry.path }
            files.append(entry)
            if files.count > Self.fileLimit { files.removeFirst(files.count - Self.fileLimit) }
        }
    }

    func clear(_ path: String, in key: String, at date: Date = Date()) async {
        await change(key, at: date) { files in files.removeAll { $0.path == path } }
    }

    /// Waits for the writes started so far (tests).
    func flush() async { await saving?.value }

    private func change(_ key: String, at date: Date, _ update: (inout [Entry]) -> Void) async {
        var all = await load()
        var scope = all.first { $0.key == key } ?? Scope(key: key, changedAt: 0, files: [])
        update(&scope.files)
        scope.changedAt = date.timeIntervalSince1970 * 1000
        all.removeAll { $0.key == key }
        if !scope.files.isEmpty { all.insert(scope, at: 0) }
        scopes = Array(all.prefix(Self.scopeLimit))
        let snapshot = scopes ?? [], url = url, previous = saving
        saving = Task {
            await previous?.value
            await Self.write(snapshot, to: url)
        }
    }

    private func load() async -> [Scope] {
        if let scopes { return scopes }
        let task = loading ?? Task { [url] in await Self.read(url) }
        loading = task
        let read = await task.value
        if scopes == nil { scopes = read }
        return scopes ?? read
    }

    @concurrent private static func read(_ url: URL) async -> [Scope] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 16 * 1024 * 1024,
              // concurrency-allow: @concurrent, one capped read of a small local file
              let data = try? Data(contentsOf: url),
              let scopes = try? JSONDecoder().decode([Scope].self, from: data) else { return [] }
        return scopes.sorted { $0.changedAt > $1.changedAt }
    }

    @concurrent private static func write(_ scopes: [Scope], to url: URL) async {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(scopes) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
