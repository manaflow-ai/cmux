public import Foundation

/// Process-wide store of in-flight file-preview drags, keyed by `UUID`.
///
/// A file-preview drag stashes its `FilePreviewDragEntry` here under a freshly
/// minted id, then carries only that id through the drag/drop machinery; the
/// drop site looks the entry back up by id. Entries expire after `entryTTL`
/// seconds so an abandoned drag (no drop, no explicit discard) cannot leak.
///
/// Faithful-lift note: this preserves the original `Sources/Panels/FilePreviewPanel.swift`
/// shape exactly — an `NSLock`-guarded mutable dictionary behind a
/// `static let shared` singleton. The lock and the singleton are intentional
/// here (not the modern `actor` target): the registry is touched from
/// synchronous AppKit drag callbacks that cannot `await`, and every call site
/// reached it through `FilePreviewDragRegistry.shared`. Behavior is byte-identical
/// to the pre-move declaration; the modernization (actor + async API) is a
/// separate change.
public final class FilePreviewDragRegistry: @unchecked Sendable {
    /// Shared process-wide registry. All drag call sites use this instance.
    public static let shared = FilePreviewDragRegistry()

    private let lock = NSLock()
    private var pending: [UUID: PendingEntry] = [:]
    private static let entryTTL: TimeInterval = 60

    private struct PendingEntry {
        let entry: FilePreviewDragEntry
        let registeredAt: Date
    }

    /// Creates an empty registry. Prefer ``shared`` for the process-wide store.
    public init() {}

    /// Registers `entry` under `id`, sweeping expired entries first, and returns `id`.
    @discardableResult
    public func register(_ entry: FilePreviewDragEntry, id: UUID = UUID(), now: Date = Date()) -> UUID {
        lock.lock()
        sweepExpiredLocked(now: now)
        pending[id] = PendingEntry(entry: entry, registeredAt: now)
        lock.unlock()
        return id
    }

    /// Removes and returns the entry for `id`, or `nil` if absent/expired.
    public func consume(id: UUID, now: Date = Date()) -> FilePreviewDragEntry? {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending.removeValue(forKey: id)?.entry
    }

    /// Returns whether a non-expired entry exists for `id`.
    public func contains(id: UUID, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending[id] != nil
    }

    /// Returns the entry for `id` without removing it, or `nil` if absent/expired.
    public func entry(id: UUID, now: Date = Date()) -> FilePreviewDragEntry? {
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked(now: now)
        return pending[id]?.entry
    }

    /// Removes the entry for `id` if present.
    public func discard(id: UUID) {
        lock.lock()
        pending.removeValue(forKey: id)
        lock.unlock()
    }

    /// Sweeps every entry older than `entryTTL`.
    public func discardExpired(now: Date = Date()) {
        lock.lock()
        sweepExpiredLocked(now: now)
        lock.unlock()
    }

    /// Removes all pending entries.
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
