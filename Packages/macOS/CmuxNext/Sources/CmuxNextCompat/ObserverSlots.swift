/// A fixed set of change observers that any thread adds to and notifies, with no lock: each observer is
/// one retained closure whose address sits in an atomic word, and an observer stays until its owner goes.
///
/// It is the list behind Chrome's `TraceLog::AddEnabledStateObserver` (base/trace_event/trace_log.h): a
/// few long-lived parties hear a rare state change (the trace categories, the typing probe's flows) on the
/// thread that made it, and post to their own thread from there.
///
/// ```swift
/// let observers = ObserverSlots<UInt64>(capacity: 4)
/// observers.add { mask in post { hook.refreshDemand() } }
/// observers.notify(newMask)
/// ```
public final class ObserverSlots<Argument>: Sendable {
    /// One added observer, retained by its word from ``add(_:)`` until the slots go.
    private final class Entry: Sendable {
        let observe: @Sendable (Argument) -> Void

        init(_ observe: @escaping @Sendable (Argument) -> Void) {
            self.observe = observe
        }
    }

    /// How many observers fit.
    public let capacity: Int
    /// One word per observer: an ``Entry`` address, 0 while free. Allocated once, never resized.
    nonisolated(unsafe) private let words: UnsafeMutablePointer<UInt64> // crash-allow: one fixed allocation; every access after init is an atomic operation (AtomicPointerSlot)

    /// Slots for up to `capacity` observers.
    public init(capacity: Int) {
        self.capacity = capacity
        words = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
        words.initialize(repeating: 0, count: capacity)
    }

    deinit {
        for index in 0..<capacity {
            entry(at: index)?.release()
        }
        words.deinitialize(count: capacity)
        words.deallocate()
    }

    /// Adds `observe`, which hears every later ``notify(_:)`` on the notifying thread.
    ///
    /// - Returns: false, and adds nothing, when all ``capacity`` slots are taken.
    @discardableResult
    public func add(_ observe: @escaping @Sendable (Argument) -> Void) -> Bool {
        let entry = Unmanaged.passRetained(Entry(observe))
        let address = UInt64(UInt(bitPattern: entry.toOpaque()))
        for index in 0..<capacity
        where AtomicPointerSlot(words + index).compareExchange(expected: 0, desired: address, ordering: .sequentiallyConsistent).exchanged {
            return true
        }
        entry.release()
        return false
    }

    /// Calls every observer added before this call with `argument`, on this thread, oldest first.
    public func notify(_ argument: Argument) {
        for index in 0..<capacity {
            entry(at: index)?._withUnsafeGuaranteedRef { $0.observe(argument) }
        }
    }

    private func entry(at index: Int) -> Unmanaged<Entry>? {
        let address = AtomicPointerSlot(words + index).load(ordering: .sequentiallyConsistent)
        return UnsafeRawPointer(bitPattern: UInt(address)).map { Unmanaged<Entry>.fromOpaque($0) }
    }
}
