import Foundation
import Synchronization

/// Which events the person has read, kept across relaunches for every event, including
/// open asks (the archive keeps only finished turns, and the Mac re-reports asks unread).
public struct FeedReadMarks: Sendable {
    public let url: URL
    /// The most marks kept.
    static let limit = 500

    public init(url: URL) {
        self.url = url
    }

    public static var standard: FeedReadMarks {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FeedReadMarks(url: base.appending(path: "Feed", directoryHint: .isDirectory).appending(path: "read.json"))
    }

    /// The marks of one account on this phone. The first load adopts the
    /// shared `read.json` of builds before per-account marks (it belonged to
    /// the account signed in then).
    public static func forAccount(_ accountID: String) -> FeedReadMarks {
        let legacy = standard.url
        let safe = accountID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        let marks = FeedReadMarks(url: legacy.deletingLastPathComponent().appending(path: "read-\(safe).json"))
        marks.adoptLegacy(legacy)
        return marks
    }

    func adoptLegacy(_ legacy: URL) {
        let files = FileManager.default
        guard !files.fileExists(atPath: url.path), files.fileExists(atPath: legacy.path) else { return }
        try? files.moveItem(at: legacy, to: url)
    }

    /// Account deletion: the account's marks go.
    public func remove() {
        let url = url
        // Empty until the delete lands; queued after any earlier write, so that write cannot
        // bring the file back, and before any later save, which then writes its marks.
        // Numbered and queued under one lock, so the queue runs operations in the order
        // they were numbered: a save on another thread can never queue ahead of this removal
        // (its write would land first and this delete would then take it).
        Self.pending.withLock { files in
            let operation = files.begin(url, .removed)
            Self.queue.async {
                // Only while still the newest: a later save then writes its marks after this.
                if Self.pending.withLock({ $0.isNewest(url, operation) }) {
                    try? FileManager.default.removeItem(at: url)
                }
                Self.pending.withLock { $0.end(url, operation) }
            }
        }
    }

    /// Writes run here, in order, off the main thread: a read mark lands while the Feed
    /// scrolls (the Mac's reads arrive several a second), and an atomic file write per mark
    /// on the main thread cost a frame.
    static let queue = DispatchQueue(label: "dev.cmux.mobile.feed.readmarks", qos: .utility)
    /// The newest marks given to `save` per file and not yet written: `load` returns them,
    /// so a reader never waits for the disk queue.
    private static let pending = Mutex(PendingFiles())

    private enum Pending: Equatable {
        case marks([String])
        /// Removed, the delete still queued: reads see nothing, and no queued write lands.
        case removed
    }

    /// Each file's newest queued operation, numbered: a queued write runs only while it is
    /// still the newest one for its file, so a write queued before a removal can never take
    /// the marks of a save queued after it (the removal would then delete them).
    private struct PendingFiles {
        var last: UInt64 = 0
        var files: [URL: (operation: UInt64, state: Pending)] = [:]

        mutating func begin(_ url: URL, _ state: Pending) -> UInt64 {
            last &+= 1
            files[url] = (last, state)
            return last
        }

        func state(_ url: URL) -> Pending? { files[url]?.state }

        func isNewest(_ url: URL, _ operation: UInt64) -> Bool { files[url]?.operation == operation }

        /// The newest marks to write when `operation` is still the file's newest.
        func marks(_ url: URL, _ operation: UInt64) -> [String]? {
            guard let entry = files[url], entry.operation == operation, case .marks(let marks) = entry.state else { return nil }
            return marks
        }

        mutating func end(_ url: URL, _ operation: UInt64) {
            if files[url]?.operation == operation { files[url] = nil }
        }
    }

    /// The marks as last saved (written or still queued).
    public func load() -> [String] {
        switch Self.pending.withLock({ $0.state(url) }) {
        case .marks(let queued): return queued
        case .removed: return []
        case nil: break
        }
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// Queues a write of the newest `limit` marks; returns at once.
    public func save(_ ids: [String]) {
        let ids = Array(ids.suffix(Self.limit))
        let url = url
        // Numbered and queued under one lock (see `remove`).
        Self.pending.withLock { files in
            let operation = files.begin(url, .marks(ids))
            Self.queue.async {
                // Only the newest operation writes (a later save or removal is queued after this).
                guard let next = Self.pending.withLock({ $0.marks(url, operation) }) else { return }
                if let data = try? JSONEncoder().encode(next) {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: url, options: [.atomic])
                }
                Self.pending.withLock { $0.end(url, operation) }
            }
        }
    }

    /// Waits until every queued write has landed (account switch, tests).
    public static func flush() { queue.sync {} }
}
