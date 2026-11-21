import Darwin
import Foundation

/// Memoizes signature-validated surface-resume approval records per store file.
///
/// Session autosave, scrollback checkpoints and restore ask for approvals once
/// per terminal on the main thread. Each uncached lookup re-read and re-parsed
/// the whole JSONC `cmux.json` and re-verified every record's HMAC, so a
/// checkpoint pass over a few hundred terminals stalled the main thread for
/// seconds (issue #35930). A lookup now costs one `stat` per backing file;
/// records are reloaded only when a file's identity, size, modification or
/// status-change time changes, or when the store reports a write.
///
/// `@unchecked Sendable` is safe because all mutable state is guarded by `lock`.
final class SurfaceResumeApprovalRecordsCache: @unchecked Sendable {
    /// The identity of one backing file; `nil` stands for a missing file.
    struct FileStamp: Hashable, Sendable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int
        var modifiedNanoseconds: Int
        /// Status-change time: unlike mtime, no tool can set it back, so an
        /// in-place rewrite that restores the old mtime still counts as a change.
        var changedSeconds: Int
        var changedNanoseconds: Int
    }

    private struct Key: Hashable {
        var stamps: [FileStamp?]
        var secret: Data
    }

    private struct Entry {
        var key: Key
        var records: [SurfaceResumeApprovalRecord]
    }

    static let shared = SurfaceResumeApprovalRecordsCache()

    private let lock = NSLock()
    private let stamp: @Sendable (URL) -> FileStamp?
    private var entries: [String: Entry] = [:]
    private var generation: UInt64 = 0
    private var changeObserver: NSObjectProtocol?

    /// - Parameters:
    ///   - stamp: Reads a file's identity; the default uses `stat(2)`.
    ///   - observesStoreWrites: Clears the cache when the store posts its
    ///     change notification, so a write in this process is never missed
    ///     even within one timestamp tick.
    init(
        stamp: @escaping @Sendable (URL) -> FileStamp? = { SurfaceResumeApprovalRecordsCache.fileStamp($0) },
        observesStoreWrites: Bool = true
    ) {
        self.stamp = stamp
        guard observesStoreWrites else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: SurfaceResumeApprovalStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    /// Returns the records `load` produces for `fileURL`, filtered to those
    /// signed with `secret`, reusing the previous answer while every file in
    /// `dependencies` (the store file and any legacy file it falls back to)
    /// is unchanged.
    func validRecords(
        fileURL: URL,
        dependencies: [URL],
        secret: Data,
        load: () -> [SurfaceResumeApprovalRecord]
    ) -> [SurfaceResumeApprovalRecord] {
        let path = fileURL.standardizedFileURL.path
        let key = Key(stamps: dependencies.map(stamp), secret: secret)
        let startGeneration: UInt64 = lock.withLock {
            generation
        }
        if let cached = lock.withLock({ entries[path] }), cached.key == key {
            return cached.records
        }
        let records = load().filter { $0.hasValidSignature(secret: secret) }
        // Cache only an answer read from files that did not change while
        // loading. A concurrent edit, or a load that migrated legacy records
        // into the store, is reread on the next lookup instead.
        let settledKey = Key(stamps: dependencies.map(stamp), secret: secret)
        lock.withLock {
            guard generation == startGeneration, settledKey == key else { return }
            entries[path] = Entry(key: key, records: records)
        }
        return records
    }

    /// Drops every cached answer.
    func invalidate() {
        lock.withLock {
            generation &+= 1
            entries.removeAll(keepingCapacity: true)
        }
    }

    static func fileStamp(_ url: URL) -> FileStamp? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileStamp(
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modifiedSeconds: Int(info.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec),
            changedSeconds: Int(info.st_ctimespec.tv_sec),
            changedNanoseconds: Int(info.st_ctimespec.tv_nsec)
        )
    }
}

extension SurfaceResumeApprovalStore {
    /// The approval store for this process. Resolving it reads the process
    /// environment and the home directory, which every terminal's session
    /// snapshot used to repeat; neither changes while the app runs.
    static func defaultURL() -> URL {
        processDefaultURL
    }

    private static let processDefaultURL = defaultURL(environment: ProcessInfo.processInfo.environment)

    /// The files whose contents determine `loadRecords(fileURL:)`.
    static func recordDependencies(for fileURL: URL) -> [URL] {
        guard fileURL.lastPathComponent == "cmux.json" else { return [fileURL] }
        return [
            fileURL,
            fileURL.deletingLastPathComponent().appendingPathComponent(legacyFileName, isDirectory: false),
        ]
    }
}
