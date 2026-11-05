import Darwin
import Foundation

/// Memoizes signature-validated surface-resume approval records per store file.
///
/// Session autosave, scrollback checkpoints and restore ask for approvals once
/// per terminal on the main thread. Each uncached lookup re-read and re-parsed
/// the whole JSONC `cmux.json` and re-verified every record's HMAC, so a
/// checkpoint pass over a few hundred terminals stalled the main thread for
/// seconds (issue #35930). A lookup now costs one `stat` per backing file;
/// records are reloaded only when a file's identity, size or modification time
/// changes, or when the store reports a write.
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
        stamp: @escaping @Sendable (URL) -> FileStamp? = SurfaceResumeApprovalRecordsCache.fileStamp,
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
        load().filter { $0.hasValidSignature(secret: secret) }
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
            modifiedNanoseconds: Int(info.st_mtimespec.tv_nsec)
        )
    }
}

extension SurfaceResumeApprovalStore {
    /// The files whose contents determine `loadRecords(fileURL:)`.
    static func recordDependencies(for fileURL: URL) -> [URL] {
        guard fileURL.lastPathComponent == "cmux.json" else { return [fileURL] }
        return [
            fileURL,
            fileURL.deletingLastPathComponent().appendingPathComponent(legacyFileName, isDirectory: false),
        ]
    }
}
