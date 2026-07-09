public import Foundation

/// In-flight registry of file-preview drags, keyed by the UUID stamped onto the
/// dragged tab's transfer payload.
///
/// A file-preview pasteboard writer registers an entry when a drag begins; the
/// pane drop target that accepts the drag looks the entry up by id and consumes
/// it. Entries that are never consumed (the drag is cancelled, or dropped on a
/// target that ignores them) expire after ``entryTTL`` and are swept on the next
/// access so the table cannot grow without bound.
///
/// Isolation: a lock-guarded reference type rather than an actor because every
/// reader is a synchronous AppKit drop/validation callback (`NSPasteboardWriting`,
/// drop-target `validateDrop`, drag-routing policy) that cannot `await`. The
/// `NSLock` makes the table safe to touch from the drag thread and the main
/// thread, which is why the type is `@unchecked Sendable`.
public final class FilePreviewDragRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [UUID: PendingEntry] = [:]
    private static let entryTTL: TimeInterval = 60

    private struct PendingEntry {
        let entry: FilePreviewDragEntry
        let registeredAt: Date
    }

    /// Creates an empty registry.
    public init() {}

    /// Registers an in-flight drag and returns the id to stamp onto the transfer.
    /// - Parameters:
    ///   - entry: the file-preview drag payload.
    ///   - id: the drag id (a fresh `UUID` by default).
    ///   - now: the registration timestamp (used for TTL sweeping; injectable for tests).
    /// - Returns: the id the entry was stored under.
    public func register(_ entry: FilePreviewDragEntry, id: UUID = UUID(), now: Date = Date()) -> UUID {
        lock.lock()
        sweepExpiredLocked(now: now)
        pending[id] = PendingEntry(entry: entry, registeredAt: now)
        lock.unlock()
        return id
    }

    /// Removes and returns the entry for `id`, or `nil` if absent or expired.
    public func consume(id: UUID, now: Date = Date()) -> FilePreviewDragEntry? {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending.removeValue(forKey: id)?.entry
    }

    /// Reports whether a live (unexpired) entry exists for `id`.
    public func contains(id: UUID, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending[id] != nil
    }

    /// Returns the entry for `id` without consuming it, or `nil` if absent or expired.
    public func entry(id: UUID, now: Date = Date()) -> FilePreviewDragEntry? {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending[id]?.entry
    }

    /// Drops the entry for `id` without sweeping the rest of the table.
    public func discard(id: UUID) {
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
    }

    /// Sweeps every entry whose TTL elapsed as of `now`.
    public func discardExpired(now: Date = Date()) {
        lock.lock()
        sweepExpiredLocked(now: now)
        lock.unlock()
    }

    /// Empties the registry.
    public func discardAll() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    private func sweepExpiredLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.entryTTL)
        pending = pending.filter { _, value in
            value.registeredAt >= cutoff
        }
    }
}
