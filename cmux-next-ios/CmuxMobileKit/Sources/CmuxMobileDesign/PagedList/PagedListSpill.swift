import Foundation
import os
import Synchronization

/// Where a bounded ``PagedListModel`` keeps the rows it holds out of memory (verify/paged-list.md,
/// "Memory"): one append-only file per list in the app's caches, read back by offset through an
/// index in memory (id → offset, length; a few dozen bytes a row). The file belongs to its model and
/// goes with it. Every list's files together stay under ``PagedListSpillBudget/capBytes`` (1 GB by
/// default); past it a row stays in memory instead, so nothing is ever lost. All file work runs in
/// order on one serial queue, off the main thread: a write queued before a read is seen by it.
final class PagedListSpill<Item: Codable & Sendable & Identifiable>: @unchecked Sendable where Item.ID: Sendable & Hashable {
    private struct Record {
        var offset: UInt64
        var length: Int
    }

    private let queue = DispatchQueue(label: "cmux.pagedlist.spill", qos: .utility)
    private let url: URL
    // Everything below is touched only on `queue`.
    private var handle: FileHandle?
    private var index: [Item.ID: Record] = [:]
    /// Rows the file could not take (the budget is spent, or a write failed): kept here instead.
    private var overflow: [Item.ID: Item] = [:]
    private var end: UInt64 = 0
    private var liveBytes = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static var log: Logger { Logger(subsystem: "dev.cmux.mobile", category: "PagedListSpill") }

    init() {
        url = PagedListSpillBudget.shared.directory.appendingPathComponent("\(UUID().uuidString).spill")
    }

    deinit {
        let url = url
        let handle = handle
        let end = end
        queue.async {
            try? handle?.close()
            try? FileManager.default.removeItem(at: url)
            PagedListSpillBudget.shared.release(Int(end))
        }
    }

    /// Writes `items` (a row written again replaces its old record).
    func write(_ items: [Item]) {
        guard !items.isEmpty else { return }
        queue.async { [self] in
            for item in items { store(item) }
            compactIfWasteful()
        }
    }

    func remove(_ ids: [Item.ID]) {
        guard !ids.isEmpty else { return }
        queue.async { [self] in
            for id in ids {
                overflow[id] = nil
                if let old = index.removeValue(forKey: id) { liveBytes -= old.length }
            }
            compactIfWasteful()
        }
    }

    func removeAll() {
        queue.async { [self] in
            overflow.removeAll()
            index.removeAll()
            liveBytes = 0
            truncate()
        }
    }

    /// Reads `ids` back; `done` runs on the main actor with the rows found (a row never written, or
    /// removed since, is absent).
    func read(_ ids: [Item.ID], done: @escaping @MainActor @Sendable ([Item.ID: Item]) -> Void) {
        queue.async { [self] in
            var found: [Item.ID: Item] = [:]
            found.reserveCapacity(ids.count)
            for id in ids {
                if let item = overflow[id] {
                    found[id] = item
                } else if let record = index[id], let item = load(record) {
                    found[id] = item
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
        }
    }

    /// Rows on disk and in the overflow, and the file's size (the lab and the bench).
    func stats(_ done: @escaping @MainActor @Sendable (_ onDisk: Int, _ inOverflow: Int, _ fileBytes: Int) -> Void) {
        queue.async { [self] in
            let counts = (index.count, overflow.count, Int(end))
            DispatchQueue.main.async { MainActor.assumeIsolated { done(counts.0, counts.1, counts.2) } }
        }
    }

    // MARK: On the queue

    private func store(_ item: Item) {
        guard let data = try? encoder.encode(item) else {
            overflow[item.id] = item
            return
        }
        guard PagedListSpillBudget.shared.take(data.count), let handle = openHandle() else {
            overflow[item.id] = item
            return
        }
        do {
            try handle.seek(toOffset: end)
            try handle.write(contentsOf: data)
        } catch {
            PagedListSpillBudget.shared.release(data.count)
            Self.log.error("spill write failed: \(error.localizedDescription, privacy: .public)")
            overflow[item.id] = item
            return
        }
        if let old = index[item.id] { liveBytes -= old.length }
        overflow[item.id] = nil
        index[item.id] = Record(offset: end, length: data.count)
        end += UInt64(data.count)
        liveBytes += data.count
    }

    private func load(_ record: Record) -> Item? {
        guard let handle = openHandle() else { return nil }
        do {
            try handle.seek(toOffset: record.offset)
            guard let data = try handle.read(upToCount: record.length), data.count == record.length else { return nil }
            return try decoder.decode(Item.self, from: data)
        } catch {
            Self.log.error("spill read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        handle = try? FileHandle(forUpdating: url)
        return handle
    }

    /// Rewrites the live records into a fresh file once more than half the file is old records.
    private func compactIfWasteful() {
        guard end > 8 << 20, Int(end) > liveBytes * 2, let handle = openHandle() else { return }
        let fresh = url.appendingPathExtension("compact")
        let manager = FileManager.default
        guard manager.createFile(atPath: fresh.path, contents: nil), let out = try? FileHandle(forWritingTo: fresh) else { return }
        var newIndex: [Item.ID: Record] = [:]
        var offset: UInt64 = 0
        do {
            for (id, record) in index {
                try handle.seek(toOffset: record.offset)
                guard let data = try handle.read(upToCount: record.length), data.count == record.length else { continue }
                try out.write(contentsOf: data)
                newIndex[id] = Record(offset: offset, length: data.count)
                offset += UInt64(data.count)
            }
            try out.close()
            try handle.close()
            self.handle = nil
            _ = try manager.replaceItemAt(url, withItemAt: fresh)
        } catch {
            Self.log.error("spill compaction failed: \(error.localizedDescription, privacy: .public)")
            try? manager.removeItem(at: fresh)
            return
        }
        PagedListSpillBudget.shared.release(Int(end) - Int(offset))
        index = newIndex
        end = offset
        liveBytes = Int(offset)
    }

    private func truncate() {
        // Nothing written yet: no file to make just to empty it.
        guard end > 0, let handle = openHandle() else { return }
        try? handle.truncate(atOffset: 0)
        PagedListSpillBudget.shared.release(Int(end))
        end = 0
    }
}

/// The disk all lists' spill files share: a cap (1 GB by default) and this launch's folder (files
/// left by an earlier launch are deleted when the first windowed list is made).
final class PagedListSpillBudget: Sendable {
    static let shared = PagedListSpillBudget()

    /// The most bytes every list's spill files may hold together.
    let capBytes: Int
    let directory: URL
    private let used = Mutex(0)

    init(capBytes: Int = 1 << 30) {
        self.capBytes = capBytes
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PagedListSpill", isDirectory: true)
        let launch = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory = launch
        // Off the main thread: an earlier launch's files go (this launch's folder is made by its first write).
        DispatchQueue.global(qos: .utility).async {
            let manager = FileManager.default
            if let old = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for folder in old where folder.lastPathComponent != launch.lastPathComponent {
                    try? manager.removeItem(at: folder)
                }
            }
        }
    }

    /// Takes `bytes` from the budget; false when that would pass the cap.
    func take(_ bytes: Int) -> Bool {
        used.withLock { used in
            guard used + bytes <= capBytes else { return false }
            used += bytes
            return true
        }
    }

    func release(_ bytes: Int) {
        used.withLock { used in used = max(0, used - bytes) }
    }

    var usedBytes: Int { used.withLock { $0 } }
}
