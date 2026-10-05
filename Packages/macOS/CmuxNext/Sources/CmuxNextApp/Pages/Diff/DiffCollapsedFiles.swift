import Foundation

/// The files a person collapsed from their header caret in the diff page (React UIs lead review
/// of S4, P2-4): `<repo root>\u{0}<path>` keys, at most ``DiffPrefKey/maximumCollapsedFiles``,
/// kept by the host next to the viewed marks (`diff-collapsed.json`), never in cmux.json. The page
/// still reads and writes them as the `collapsedFiles` pref (`cmux.diff.prefs.*`). Reads and writes
/// run off the main actor, writes in order.
final class DiffCollapsedFiles {
    static let fileName = "diff-collapsed.json"

    let url: URL
    private var files: [String]?
    private var loading: Task<[String], Never>?
    private var saving: Task<Void, Never>?

    init(url: URL) {
        self.url = url
    }

    /// Next to the viewed marks (and the recents).
    static func standardURL(viewed: URL) -> URL {
        viewed.deletingLastPathComponent().appending(path: fileName)
    }

    func list() async -> [String] { await load() }

    /// Replaces the list (an empty list removes the file's entries).
    func set(_ entries: [String]) async {
        _ = await load()
        files = Array(entries.suffix(DiffPrefKey.maximumCollapsedFiles))
        let snapshot = files ?? [], url = url, previous = saving
        saving = Task {
            await previous?.value
            await Self.write(snapshot, to: url)
        }
    }

    /// Waits for the writes started so far (tests).
    func flush() async { await saving?.value }

    private func load() async -> [String] {
        if let files { return files }
        let task = loading ?? Task { [url] in await Self.read(url) }
        loading = task
        let read = await task.value
        if files == nil { files = read }
        return files ?? read
    }

    @concurrent private static func read(_ url: URL) async -> [String] {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4 * 1024 * 1024,
              // concurrency-allow: @concurrent, one capped read of a small local file
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(entries.suffix(DiffPrefKey.maximumCollapsedFiles))
    }

    @concurrent private static func write(_ entries: [String], to url: URL) async {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
