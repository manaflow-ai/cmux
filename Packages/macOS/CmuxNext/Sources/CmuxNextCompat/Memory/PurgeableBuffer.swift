public import CoreFoundation
public import Foundation

/// Bytes in ``PurgeablePages`` that are volatile while no reader holds them, Chrome's
/// `base::DiscardableMemory` (base/memory/discardable_memory.h): a reader locks them, a failed lock means
/// the kernel took them, and the last reader's unlock makes them volatile again.
///
/// A reader holds the bytes through the `CFData` of ``lockedData()``, which keeps them locked until it is
/// freed, on any thread: an image made over it (``PurgeableBitmap/image()``) keeps them locked while
/// Core Animation or a view still draws it, and no pixel is copied per draw. Once purged a buffer stays
/// purged, and its owner drops it (a miss), as Chrome's decoded image cache drops a decode whose lock fails
/// (`cc/tiles/software_image_decode_cache.cc`).
public final class PurgeableBuffer: Sendable {
    /// The bytes it holds.
    public let byteCount: Int
    private let pages: any PurgeablePages
    private let state = Mutex(State())

    private struct State {
        /// Readers holding the bytes non-volatile.
        var locks = 0
        var purged = false
        /// The owner's count of locked bytes, nil while no cache holds it.
        var ledger: PurgeableLedger?
    }

    /// Fills new pages through `fill`, then makes them volatile.
    ///
    /// - Parameters:
    ///   - byteCount: The bytes it holds.
    ///   - allocator: Makes the pages.
    ///   - fill: Writes the `byteCount` bytes at the pointer; false gives up (nil).
    init?(byteCount: Int, allocator: PurgeableAllocator, fill: (UnsafeMutableRawPointer) -> Bool) {
        guard byteCount > 0, let pages = allocator.pages(byteCount: byteCount), pages.byteCount >= byteCount,
              let base = unsafe pages.baseAddress, unsafe fill(base) else { return nil }
        self.byteCount = byteCount
        self.pages = pages
        pages.makeVolatile()
    }

    /// A copy of `data` in new pages, volatile.
    ///
    /// - Parameters:
    ///   - data: The bytes to keep (an encoded picture).
    ///   - allocator: Makes the pages.
    public convenience init?(copying data: Data, allocator: PurgeableAllocator) {
        self.init(byteCount: data.count, allocator: allocator) { base in
            data.withUnsafeBytes { source in
                // SAFETY: `base` points at `data.count` writable bytes (the pages hold at least that many), and the
                // copy writes exactly `source.count` of them.
                unsafe UnsafeMutableRawBufferPointer(start: base, count: source.count).copyMemory(from: source)
            }
            return true
        }
    }

    /// Whether the kernel took the bytes (seen at a lock).
    public var isPurged: Bool { state.withLock { $0.purged } }

    /// The bytes, locked until the returned data is freed; nil when the kernel purged them.
    public func lockedData() -> CFData? {
        guard lock() else { return nil }
        guard let base = unsafe pages.baseAddress else {
            unlock()
            return nil
        }
        // SAFETY: `base` maps `byteCount` bytes for as long as `pages` lives, and the deallocator keeps `self` (and
        // so `pages`) alive until the data is freed; it frees nothing, it only ends this reader's lock.
        let data = unsafe NSData(bytesNoCopy: base, length: byteCount, deallocator: { _, _ in self.unlock() })
        return data as CFData
    }

    /// Moves the buffer's locked bytes to `ledger` (nil: no cache holds it now).
    ///
    /// - Parameter ledger: The holding cache's ledger.
    public func attach(to ledger: PurgeableLedger?) {
        state.withLock { state in
            guard state.ledger !== ledger else { return }
            if !pages.isPurgeable || state.locks > 0 {
                state.ledger?.subtract(byteCount)
                ledger?.add(byteCount)
            }
            state.ledger = ledger
        }
    }

    /// One more reader; false when the kernel purged the bytes.
    private func lock() -> Bool {
        state.withLock { state in
            if state.purged { return false }
            if state.locks == 0 {
                guard pages.makeNonVolatile() else {
                    state.purged = true
                    // The emptied pages came back zeroed and non-volatile: give them back to the kernel at once.
                    pages.makeVolatile()
                    return false
                }
                if pages.isPurgeable { state.ledger?.add(byteCount) }
            }
            state.locks += 1
            return true
        }
    }

    /// A reader ended; the last one makes the bytes volatile again.
    private func unlock() {
        state.withLock { state in
            state.locks -= 1
            guard state.locks == 0 else { return }
            pages.makeVolatile()
            if pages.isPurgeable { state.ledger?.subtract(byteCount) }
        }
    }
}
