import CmuxNextCompat
import Foundation

/// Purgeable pages a test empties on demand (the ``PurgeablePages`` seam): heap bytes whose
/// volatile state is a flag, emptied by ``purge()`` only while volatile, as memory pressure would.
nonisolated final class FakePurgeablePages: PurgeablePages {
    private struct State {
        var isVolatile = false
        var isEmpty = false
    }

    private let bytes: ResidentPages
    private let state = Mutex(State())

    init?(byteCount: Int) {
        guard let bytes = ResidentPages(byteCount: byteCount) else { return nil }
        self.bytes = bytes
    }

    var baseAddress: UnsafeMutableRawPointer? { unsafe bytes.baseAddress }
    var byteCount: Int { bytes.byteCount }
    var isPurgeable: Bool { true }
    /// Whether nothing reads the pages now.
    var isVolatile: Bool { state.withLock { $0.isVolatile } }

    func makeVolatile() {
        state.withLock { $0.isVolatile = true }
    }

    func makeNonVolatile() -> Bool {
        state.withLock { state in
            state.isVolatile = false
            return !state.isEmpty
        }
    }

    /// Takes the pages as memory pressure would: only volatile ones.
    ///
    /// - Returns: Whether they were taken.
    @discardableResult
    func purge() -> Bool {
        state.withLock { state in
            guard state.isVolatile else { return false }
            state.isEmpty = true
            return true
        }
    }
}

/// An allocator of ``FakePurgeablePages`` that keeps every pages it made, in order, for a test to purge, and
/// whether each was made on the main thread (a picture's pixels are copied where its pages are made).
nonisolated final class FakePurgeableAllocations: Sendable {
    private let made = Mutex<[(pages: FakePurgeablePages, onMain: Bool)]>([])

    var allocator: PurgeableAllocator {
        PurgeableAllocator { [self] count in
            let pages = FakePurgeablePages(byteCount: count)
            let onMain = Thread.isMainThread
            if let pages { made.withLock { $0.append((pages, onMain)) } }
            return pages
        }
    }

    /// Every pages made so far, oldest first.
    var pages: [FakePurgeablePages] { made.withLock { $0.map { $0.pages } } }

    /// How many pages were made on the main thread.
    var madeOnMain: Int { made.withLock { $0.filter { $0.onMain }.count } }
}
