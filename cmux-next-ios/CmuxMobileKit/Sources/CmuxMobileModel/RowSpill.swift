import Foundation
#if os(iOS)
import CmuxMobileLinkFFI
#endif

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
    /// The pages: Rust's `RowSpillPages` (cmux-mobile-link-ffi row_spill.rs) on iOS. Each row
    /// goes in as its JSON; only `queue` calls it, so calls keep their order.
    private let pages: Pages

    public init(directory: URL, pageSize: Int = 100, maxRows: Int = 20_000) {
        precondition(pageSize > 0 && maxRows >= pageSize, "a spill holds at least one page")
        self.directory = directory
        self.pageSize = pageSize
        self.maxRows = maxRows
        queue = DispatchQueue(label: "dev.cmux.mobile.row-spill.\(directory.lastPathComponent)", qos: .utility)
        pages = Pages(directory: directory, pageSize: pageSize, maxRows: maxRows)
    }

    /// The spill for one list under Caches: `name` is the list ("feed"), `scope` its owner
    /// (an account or a chat id), sanitized into a folder name.
    public static func inCaches(_ name: String, scope: String, pageSize: Int = 100, maxRows: Int = 20_000) -> RowSpill {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appending(path: "RowSpill", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
            .appending(path: RowSpillRun.folderName(scope), directoryHint: .isDirectory)
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
            let parent = root.deletingLastPathComponent().path
            let current = root.lastPathComponent
            DispatchQueue.global(qos: .utility).async { RowSpillRun.purgeRuns(parent, keep: current) }
        }
        return RowSpill(directory: root.appending(path: RowSpillRun.folderName(scope), directoryHint: .isDirectory),
                        pageSize: pageSize, maxRows: maxRows)
    }

    /// Deletes the spill without waiting (its owner is going away). Writes queued before it
    /// run first.
    public func discard() {
        let pages = pages
        queue.async { pages.reset() }
    }

    /// Keeps `rows` (newest first, all older than what the list still holds) on disk.
    /// Returns at once; the write happens on the spill's queue.
    public func push(_ rows: [Row]) {
        guard !rows.isEmpty else { return }
        let pages = pages
        queue.async {
            // JSON, not a property list: rows carry JSON nulls (tool output) a plist cannot hold.
            let encoder = JSONEncoder()
            pages.push(rows: rows.compactMap { try? encoder.encode($0) })
        }
    }

    /// Takes the newest page off disk (newest first), or nothing when the spill is empty.
    public func pop() async -> [Row] {
        let pages = pages
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.decode(pages.pop())) }
        }
    }

    /// Deletes every spilled row. Waits for writes already queued, so none lands after it
    /// (sign-out, a new session of the list).
    public func reset() {
        queue.sync { pages.reset() }
    }

    /// Returns once every push made before it is written (tests and measurements).
    public func flush() {
        queue.sync {}
    }

    /// The rows short of a page that wait in memory, newest first (tests and measurements).
    public func rowsInMemory() -> [Row] {
        queue.sync { Self.decode(pages.rowsInMemory()) }
    }

    /// How many rows are on disk (tests and measurements; reads every page).
    public func storedCount() -> Int {
        queue.sync { Int(pages.storedCount()) }
    }

    private static func decode(_ rows: [Data]) -> [Row] {
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(Row.self, from: $0) }
    }
}

#if os(iOS)
private typealias Pages = RowSpillPages

extension RowSpillPages {
    fileprivate convenience init(directory: URL, pageSize: Int, maxRows: Int) {
        self.init(directory: directory.path, pageSize: UInt32(clamping: pageSize), maxRows: UInt32(clamping: maxRows))
    }
}
#else
/// Where Rust does not link (the macOS and Linux package builds, which have no phone UI) the
/// pages stay in memory: the same order and cap, no files.
private final class Pages: @unchecked Sendable {
    // Read and written on the spill's queue only. Newest first.
    private var held: [Data] = []
    private let pageSize: Int
    private let maxRows: Int

    init(directory: URL, pageSize: Int, maxRows: Int) {
        self.pageSize = pageSize
        self.maxRows = maxRows
    }

    func push(rows: [Data]) {
        held = rows + held
        let limit = held.count % pageSize + max(1, maxRows / pageSize) * pageSize
        if held.count > limit { held.removeLast(held.count - limit) }
    }

    func pop() -> [Data] {
        let short = held.count % pageSize
        let rows = Array(held.prefix(short == 0 ? pageSize : short))
        held.removeFirst(rows.count)
        return rows
    }

    func reset() { held = [] }
    func rowsInMemory() -> [Data] { Array(held.prefix(held.count % pageSize)) }
    func storedCount() -> UInt32 { UInt32(held.count) }
}
#endif

/// This run of the app, for spills that must not outlive it (`RowSpill.forThisRun`).
@MainActor
final class RowSpillRun {
    static let id = UUID().uuidString
    /// Lists whose earlier runs' spills were deleted in this run.
    static var purged: Set<String> = []

    /// `scope` as one folder name (Rust's `row_spill_folder_name`).
    nonisolated static func folderName(_ scope: String) -> String {
        #if os(iOS)
        rowSpillFolderName(scope: scope)
        #else
        scope.isEmpty ? "default" : String(scope.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        #endif
    }

    /// Deletes every folder under `parent` but `keep` (Rust's `row_spill_purge_runs`).
    nonisolated static func purgeRuns(_ parent: String, keep: String) {
        #if os(iOS)
        rowSpillPurgeRuns(parent: parent, keep: keep)
        #endif
    }
}
