#if DEBUG
import AppKit

/// The per-thread depths behind ``GeometryReentrancyGuard``: each thread
/// keeps its own ``GeometryDepthTable`` in a thread-specific slot, so a
/// call reads and writes only its own thread's memory and takes no lock.
nonisolated final class GeometryReentrancyGate: Sendable {
    let limit: Int
    private let key: pthread_key_t?
    /// A refused call, and whether it is the thread's first for its view
    /// class and callback (any thread).
    private let refused: @Sendable (GeometryReentrancyGuard.Report, Bool) -> Void

    init(limit: Int, refused: @escaping @Sendable (GeometryReentrancyGuard.Report, Bool) -> Void) {
        self.limit = limit
        self.refused = refused
        var key = pthread_key_t()
        // SAFETY: pthread_key_create writes one key into `key`, a local; the destructor is a
        // @convention(c) global that lives for the process.
        self.key = unsafe pthread_key_create(&key, releaseGeometryThreadDepths) == 0 ? key : nil
    }

    deinit {
        // A thread's table for a deleted key is not released: it leaks, a few words per thread.
        if let key { pthread_key_delete(key) }
    }

    /// Runs `body` unless `object` is already inside `callback` ``limit``
    /// times on this thread; a refused call does not run `body`.
    @discardableResult
    func run(_ object: AnyObject, _ callback: GeometryReentrancyGuard.Callback, _ body: () -> Void) -> Bool {
        guard let depths = threadDepths() else {
            body()
            return true
        }
        let type: AnyClass = Swift.type(of: object)
        let id = ObjectIdentifier(object)
        switch depths.table.enter(id, type: ObjectIdentifier(type), callback, limit: limit) {
        case .entered:
            body()
            depths.table.exit(id, callback)
            return true
        case let .refused(depth, first):
            refused(GeometryReentrancyGuard.Report(viewClass: String(describing: type), callback: callback, depth: depth, at: Date()), first)
            return false
        }
    }

    /// One thread's depths: only that thread reads or writes it.
    nonisolated final class ThreadDepths {
        var table = GeometryDepthTable()
    }

    /// Forgets the calling thread's depths (none is open between run loop turns).
    func clearCurrentThread() {
        guard let key, let raw = unsafe pthread_getspecific(key) else { return }
        // SAFETY: the slot holds a pointer made by passRetained in threadDepths, released only by the destructor.
        unsafe Unmanaged<ThreadDepths>.fromOpaque(raw).takeUnretainedValue().table.clearDepths()
    }

    /// The calling thread's table, made at its first call; nil when the process has no key or slot left.
    private func threadDepths() -> ThreadDepths? {
        guard let key else { return nil }
        if let raw = unsafe pthread_getspecific(key) {
            // SAFETY: as in clearCurrentThread.
            return unsafe Unmanaged<ThreadDepths>.fromOpaque(raw).takeUnretainedValue()
        }
        let depths = ThreadDepths()
        let raw = unsafe Unmanaged.passRetained(depths).toOpaque()
        // SAFETY: stores the retained pointer; the key's destructor releases it when the thread exits.
        guard unsafe pthread_setspecific(key, raw) == 0 else {
            // SAFETY: `raw` was retained above and stored nowhere.
            unsafe Unmanaged<ThreadDepths>.fromOpaque(raw).release()
            return nil
        }
        return depths
    }
}

/// Releases a thread's ``GeometryReentrancyGate/ThreadDepths`` when the thread exits.
nonisolated private func releaseGeometryThreadDepths(_ raw: UnsafeMutableRawPointer) {
    // SAFETY: the slot held the pointer threadDepths retained; the thread is gone, so nothing reads it again.
    unsafe Unmanaged<GeometryReentrancyGate.ThreadDepths>.fromOpaque(raw).release()
}

/// The open depth of each view and callback on one thread, and the view
/// classes already reported per callback.
nonisolated struct GeometryDepthTable {
    nonisolated enum Entry: Equatable {
        case entered
        /// Refused at `depth`; `first` for the first refusal of the view class in the callback.
        case refused(depth: Int, first: Bool)
    }

    private nonisolated struct Key: Hashable {
        let object: ObjectIdentifier
        let callback: GeometryReentrancyGuard.Callback
    }

    private nonisolated struct ReportedKey: Hashable {
        let type: ObjectIdentifier
        let callback: GeometryReentrancyGuard.Callback
    }

    private var depths: [Key: Int] = [:]
    private var reported: Set<ReportedKey> = []

    /// No call open.
    var isIdle: Bool { depths.isEmpty }

    /// The open depth of `object` in `callback`.
    func depth(of object: ObjectIdentifier, _ callback: GeometryReentrancyGuard.Callback) -> Int {
        depths[Key(object: object, callback: callback)] ?? 0
    }

    /// Opens one call of `callback` on `object`, unless `limit` are already open.
    mutating func enter(_ object: ObjectIdentifier, type: ObjectIdentifier, _ callback: GeometryReentrancyGuard.Callback,
                        limit: Int) -> Entry {
        let key = Key(object: object, callback: callback)
        let depth = (depths[key] ?? 0) + 1
        guard depth <= limit else {
            return .refused(depth: depth, first: reported.insert(ReportedKey(type: type, callback: callback)).inserted)
        }
        depths[key] = depth
        return .entered
    }

    /// Closes the innermost call of `callback` on `object`; nothing when none is open.
    mutating func exit(_ object: ObjectIdentifier, _ callback: GeometryReentrancyGuard.Callback) {
        let key = Key(object: object, callback: callback)
        guard let depth = depths[key] else { return }
        depths[key] = depth > 1 ? depth - 1 : nil
    }

    /// Closes every open call (the reported classes stay reported).
    mutating func clearDepths() {
        if !depths.isEmpty { depths.removeAll() }
    }
}
#endif
