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
        // Empty until the delete lands; queued after any write, so a write cannot bring the file back.
        Self.pending.withLock { $0[url] = .removed }
        Self.queue.async {
            try? FileManager.default.removeItem(at: url)
            Self.pending.withLock { if $0[url] == .removed { $0[url] = nil } }
        }
    }

    /// Writes run here, in order, off the main thread: a read mark lands while the Feed
    /// scrolls (the Mac's reads arrive several a second), and an atomic file write per mark
    /// on the main thread cost a frame.
    static let queue = DispatchQueue(label: "dev.cmux.mobile.feed.readmarks", qos: .utility)
    /// The newest marks given to `save` per file and not yet written: `load` returns them,
    /// so a reader never waits for the disk queue.
    private static let pending = Mutex<[URL: Pending]>([:])

    private enum Pending: Equatable {
        case marks([String])
        /// Removed, the delete still queued: reads see nothing, and no queued write lands.
        case removed
    }

    /// The marks as last saved (written or still queued).
    public func load() -> [String] {
        switch Self.pending.withLock({ $0[url] }) {
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
        Self.pending.withLock { $0[url] = .marks(ids) }
        Self.queue.async {
            // Only the newest marks are written (nil: already written; removed: none).
            guard case .marks(let next) = Self.pending.withLock({ $0[url] }) else { return }
            if let data = try? JSONEncoder().encode(next) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url, options: [.atomic])
            }
            Self.pending.withLock { if $0[url] == .marks(next) { $0[url] = nil } }
        }
    }

    /// Waits until every queued write has landed (account switch, tests).
    public static func flush() { queue.sync {} }
}
