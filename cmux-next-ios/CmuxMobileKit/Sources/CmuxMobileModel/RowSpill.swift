import Foundation

/// Rows a long list dropped from memory, kept on disk while the app runs so scrolling back
/// brings them back without holding them in RAM (Chrome's Memory Saver, for list rows).
///
/// The spill is a stack of page files: a list evicts its oldest rows from the bottom of its
/// window, so each eviction is newer than every page already on disk, and scrolling back reads
/// the newest page first. A pop reads and deletes one page. Every read and write runs in order on one utility queue, off
/// the main thread; `pop` answers on that queue, after every push made before it. The newest
/// rows short of a page wait in memory (at most `pageSize - 1`) until the page fills.
///
/// It is a cache, not an archive: it lives under Caches (the system may purge it), every
/// spill starts empty (`reset`), and it holds at most `maxRows` rows: past that the oldest
/// page is dropped, the way the list dropped it before there was a spill.
public struct RowSpill<Row: Codable & Sendable>: Sendable {
    public let directory: URL
    /// Rows per page file: one pop brings back this many.
    public let pageSize: Int
    /// The most rows kept on disk; older pages are deleted.
    public let maxRows: Int

    let queue: DispatchQueue
    /// The newest rows, fewer than a page, held until a page fills (on `queue` only): a list
    /// that evicts one row per event writes a file per page, not a page rewrite per event.
    private let tail = Tail()

    private final class Tail: @unchecked Sendable {
        // Read and written on the spill's queue only.
        var rows: [Row] = []
    }

    public init(directory: URL, pageSize: Int = 100, maxRows: Int = 20_000) {
        precondition(pageSize > 0 && maxRows >= pageSize, "a spill holds at least one page")
        self.directory = directory
        self.pageSize = pageSize
        self.maxRows = maxRows
        queue = DispatchQueue(label: "dev.cmux.mobile.row-spill.\(directory.lastPathComponent)", qos: .utility)
    }

    /// The spill for one list under Caches: `name` is the list ("feed"), `scope` its owner
    /// (an account or a chat id), sanitized into a folder name.
    public static func inCaches(_ name: String, scope: String, pageSize: Int = 100, maxRows: Int = 20_000) -> RowSpill {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let safe = scope.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        let directory = base.appending(path: "RowSpill", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: safe.isEmpty ? "default" : safe, directoryHint: .isDirectory)
        return RowSpill(directory: directory, pageSize: pageSize, maxRows: maxRows)
    }

    /// A spill for one owner that lives only for this run of the app: under
    /// Caches/RowSpill/`name`/<this run>/`scope`. The first one of a run deletes the folders
    /// earlier runs left (a killed app never deleted its spills); this run's folder is never
    /// among them.
    @MainActor
    public static func forThisRun(_ name: String, scope: String, pageSize: Int = 100, maxRows: Int = 20_000) -> RowSpill {
        let root = inCaches(name, scope: RowSpillRun.id).directory
        if RowSpillRun.purged.insert(name).inserted {
            let parent = root.deletingLastPathComponent()
            let current = root.lastPathComponent
            DispatchQueue.global(qos: .utility).async {
                let runs = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
                for run in runs where run.lastPathComponent != current { try? FileManager.default.removeItem(at: run) }
            }
        }
        let safe = scope.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return RowSpill(directory: root.appending(path: safe, directoryHint: .isDirectory), pageSize: pageSize, maxRows: maxRows)
    }

    /// Deletes the spill without waiting (its owner is going away). Writes queued before it
    /// run first.
    public func discard() {
        let directory = directory, tail = tail
        queue.async {
            tail.rows = []
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Keeps `rows` (newest first, all older than what the list still holds) on disk.
    /// Returns at once; the write happens on the spill's queue.
    public func push(_ rows: [Row]) {
        guard !rows.isEmpty else { return }
        queue.async { write(rows) }
    }

    /// Takes the newest page off disk (newest first), or nothing when the spill is empty.
    public func pop() async -> [Row] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read()) }
        }
    }

    /// Deletes every spilled row. Waits for writes already queued, so none lands after it
    /// (sign-out, a new session of the list).
    public func reset() {
        queue.sync {
            tail.rows = []
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Returns once every push made before it is written (tests and measurements).
    public func flush() {
        queue.sync {}
    }

    /// How many rows are on disk (tests and measurements; reads every page).
    public func storedCount() -> Int {
        queue.sync { tail.rows.count + pages().reduce(0) { $0 + (load($1)?.count ?? 0) } }
    }

    // MARK: On the queue

    private func pages() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "page" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func load(_ url: URL) -> [Row]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Row].self, from: data)
    }

    private func store(_ rows: [Row], at url: URL) {
        // JSON, not a property list: rows carry JSON nulls (tool output) a plist cannot hold.
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func pageURL(_ sequence: Int) -> URL {
        directory.appending(path: String(format: "%012d.page", sequence))
    }

    private func sequence(of url: URL) -> Int {
        Int(url.deletingPathExtension().lastPathComponent) ?? 0
    }

    /// `rows` are newer than every row held: they go on top. Whole pages go to disk, oldest
    /// first; fewer than a page stay in `tail` until more arrive.
    private func write(_ rows: [Row]) {
        // Newest first: the new rows sit above the tail's.
        let pending = rows + tail.rows
        let whole = pending.count / pageSize * pageSize
        tail.rows = Array(pending.prefix(pending.count - whole))
        guard whole > 0 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var existing = pages()
        var next = (existing.last.map(sequence) ?? 0) + 1
        // The oldest rows fill the lower pages.
        var end = pending.count
        while end > pending.count - whole {
            let start = end - pageSize
            store(Array(pending[start..<end]), at: pageURL(next))
            existing.append(pageURL(next))
            next += 1
            end = start
        }
        // Past the cap the oldest pages go, as the list dropped rows before there was a spill.
        let maxPages = max(1, maxRows / pageSize)
        if existing.count > maxPages {
            for url in existing.prefix(existing.count - maxPages) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func read() -> [Row] {
        if !tail.rows.isEmpty {
            defer { tail.rows = [] }
            return tail.rows
        }
        guard let top = pages().last else { return [] }
        let rows = load(top) ?? []
        try? FileManager.default.removeItem(at: top)
        return rows
    }
}

/// This run of the app, for spills that must not outlive it (`RowSpill.forThisRun`).
@MainActor
final class RowSpillRun {
    static let id = UUID().uuidString
    /// Lists whose earlier runs' spills were deleted in this run.
    static var purged: Set<String> = []
}
