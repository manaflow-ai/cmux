public import CmuxNextCompat
import Foundation
import os

/// The files a person collapsed from their header caret in the diff page (React UIs lead review
/// of S4, P2-4): `<repo root>\u{0}<path>` keys, at most ``DiffPrefKey/maximumCollapsedFiles``,
/// kept by the host next to the viewed marks (`diff-collapsed.json`), never in cmux.json. The page
/// still reads and writes them as the `collapsedFiles` pref (`cmux.diff.prefs.*`). Reads and writes
/// run on the runner's files lane, writes in order.
public final class DiffCollapsedFiles {
    static let fileName = "diff-collapsed.json"

    let url: URL
    /// The app's blocking-work lanes: the file reads and writes run there, never on the pool.
    let runner: any MayBlockRunner
    private var files: [String]?
    private var loading: Task<[String]?, Never>?
    private var saving: Task<Void, Never>?

    init(url: URL, runner: any MayBlockRunner) {
        self.url = url
        self.runner = runner
    }

    /// Next to the viewed marks (and the recents).
    static func standardURL(viewed: URL) -> URL {
        viewed.deletingLastPathComponent().appending(path: fileName)
    }

    /// The list; none when the read was refused (quit began).
    func list() async -> [String] { await load() ?? [] }

    /// Replaces the list (an empty list removes the file's entries).
    /// Drops the change when the file could not be read (quit began), as the other diff stores do.
    func set(_ entries: [String]) async {
        guard await load() != nil else { return }
        files = Array(entries.suffix(DiffPrefKey.maximumCollapsedFiles))
        let snapshot = files ?? [], url = url, runner = runner, previous = saving
        saving = Task {
            await previous?.value
            await Self.write(snapshot, to: url, on: runner)
        }
    }

    /// Waits for the writes started so far (tests).
    func flush() async { await saving?.value }

    /// The list, read once; nil when the read was refused (the next call reads again).
    private func load() async -> [String]? {
        if let files { return files }
        let task = loading ?? Task { [url, runner] in await Self.read(url, on: runner) }
        loading = task
        guard let read = await task.value else {
            loading = nil
            return nil
        }
        if files == nil { files = read }
        return files ?? read
    }

    /// The file's entries ([] for a missing or unreadable file); nil when the lane refused the read (quit
    /// began, or the caller was cancelled), which is not an empty file.
    private static func read(_ url: URL, on runner: any MayBlockRunner) async -> [String]? {
        try? await runner.runFiles(.userVisible) { () -> [String] in
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 4 * 1024 * 1024,
                  let data = try? Data(blockingContentsOf: url),
                  let entries = try? JSONDecoder().blockingDecode([String].self, from: data) else { return [] }
            return Array(entries.suffix(DiffPrefKey.maximumCollapsedFiles))
        }
    }

    /// One small atomic replace, so quit waits for it (a collapse made just before quit stays).
    private static func write(_ entries: [String], to url: URL, on runner: any MayBlockRunner) async {
        do {
            try await runner.runFiles(.bestEffort, shutdown: .blockShutdown) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            }
        } catch is CancellationError {
            return
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "diff-collapsed")
                .error("collapsed files not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}
