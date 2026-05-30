// SPDX-License-Identifier: MIT

import Foundation

/// Per-surface concurrent-stream limiter (D7).
///
/// Tracks open SSE streams per ``SurfaceHandle`` against a fixed cap
/// (default 8). Callers acquire a slot via ``acquire(surface:)`` which
/// returns a ``Token`` on success or `nil` when the surface is at cap.
/// Releasing the token frees the slot.
///
/// The token's ``Token/release()`` is **idempotent** (CAS-guarded so
/// double-release is safe) and **NOT recursive** (D24 — the public
/// `release()` calls the stored closure once via the released flag).
public final class StreamCap: @unchecked Sendable {
    /// Maximum concurrent streams per surface. Default 8 per spec §9.1.
    public let maxPerSurface: Int

    private let lock = NSLock()
    private var counts: [SurfaceHandle: Int] = [:]

    /// Creates a per-surface stream cap.
    ///
    /// - Parameter maxPerSurface: positive ceiling; defaults to 8.
    public init(maxPerSurface: Int = 8) {
        precondition(maxPerSurface > 0)
        self.maxPerSurface = maxPerSurface
    }

    /// Attempts to acquire one slot for ``surface``. Returns a release
    /// ``Token`` on success or `nil` when the surface is already at
    /// ``maxPerSurface`` open streams.
    public func acquire(surface: SurfaceHandle) -> Token? {
        lock.lock(); defer { lock.unlock() }
        let cur = counts[surface, default: 0]
        guard cur < maxPerSurface else { return nil }
        counts[surface] = cur + 1
        return Token(surface: surface, owner: self)
    }

    /// Current usage. Used by tests and metrics; safe to call from any
    /// thread.
    public func openCount(for surface: SurfaceHandle) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[surface, default: 0]
    }

    fileprivate func releaseSlot(for surface: SurfaceHandle) {
        lock.lock(); defer { lock.unlock() }
        let cur = counts[surface, default: 0]
        if cur > 0 { counts[surface] = cur - 1 }
    }

    /// Opaque release token. Calling ``release()`` more than once is
    /// safe; only the first call drops the slot.
    public final class Token: @unchecked Sendable {
        fileprivate let surface: SurfaceHandle
        fileprivate weak var owner: StreamCap?
        private let releasedLock = NSLock()
        private var released: Bool = false

        fileprivate init(surface: SurfaceHandle, owner: StreamCap) {
            self.surface = surface
            self.owner = owner
        }

        /// Releases this slot. Idempotent — subsequent calls no-op.
        public func release() {
            releasedLock.lock()
            let wasReleased = released
            if !wasReleased { released = true }
            releasedLock.unlock()
            guard !wasReleased else { return }
            owner?.releaseSlot(for: surface)
        }

        deinit { release() }
    }
}
