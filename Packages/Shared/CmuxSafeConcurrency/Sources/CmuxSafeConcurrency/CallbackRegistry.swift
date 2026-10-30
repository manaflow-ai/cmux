internal import CmuxSafeConcurrencyAtomics

/// The context a C callback gets back for a ``CallbackRegistry`` entry: a slot index and that slot's generation,
/// never a pointer to the object. A token outlives nothing: once its entry is unregistered (or its object is gone)
/// the registry ignores it and counts it.
public struct CallbackToken: Hashable, Sendable {
    /// The generation in the high 32 bits, the slot index + 1 in the low 32 bits; 0 names no entry.
    public let rawValue: UInt

    init(generation: UInt32, index: Int) {
        rawValue = UInt(generation) << 32 | UInt(truncatingIfNeeded: index + 1)
    }

    /// The token a C callback received as its context (nil reads as the token that names no entry).
    @safe public init(context: UnsafeMutableRawPointer?) {
        // SAFETY: only the pointer's bits are read; it is never dereferenced.
        rawValue = unsafe UInt(bitPattern: context)
    }

    /// The token as a C context (FSEventStreamContext.info, an event tap's userInfo): C only hands it back to the
    /// callback, which reads it with ``init(context:)``. Nothing dereferences it.
    @safe public var context: UnsafeMutableRawPointer? {
        // SAFETY: the bits of a token, never dereferenced (see above).
        unsafe UnsafeMutableRawPointer(bitPattern: rawValue)
    }

    var generation: UInt32 { UInt32(truncatingIfNeeded: rawValue >> 32) }

    /// The slot index, or nil for a token no slot of `capacity` can have.
    func index(below capacity: Int) -> Int? {
        let slot = Int(truncatingIfNeeded: rawValue & 0xFFFF_FFFF) - 1
        return slot >= 0 && slot < capacity ? slot : nil
    }

    /// `object` at +0 for a C callback that hands back the object C passed it (a Quartz event tap returns its
    /// event to let it through). C owns the object for the whole call and nothing keeps the pointer after it, so
    /// this is not a context: contexts are tokens. The one unretained pass the callback sites keep (p10 Q08).
    @unsafe public static func passingBack<Object: AnyObject>(_ object: Object) -> Unmanaged<Object> {
        unsafe Unmanaged.passUnretained(object)
    }
}

/// A full ``CallbackRegistry``: every slot holds a live entry.
public enum CallbackRegistryError: Error, Equatable, Sendable {
    case full(capacity: Int)
}

/// Bits of a slot's state word: the readers inside a lookup, then the claimed and live flags, then the generation.
private let readerMask: UInt64 = (1 << 30) - 1
private let claimedBit: UInt64 = 1 << 30
private let liveBit: UInt64 = 1 << 31

/// Maps the context of a C callback to its Swift object without an unretained pointer (Chromium's MiraclePtr
/// goal for raw pointers, here as `base::IDMap` ids handed to C, base/containers/id_map.h, that resolve to a
/// weak reference, base/memory/weak_ptr.h). `register` gives a ``CallbackToken``, the C context; the callback
/// calls ``target(for:)`` and gets the object, or nil for a token that was unregistered, reused, forged, or whose
/// object is gone: the registry ignores that token and counts it (``ignoredCount``), so a callback that fires
/// after its owner went away (a use after free with `passUnretained`) does nothing.
///
/// A fixed table of slots, each a 64-bit state word (generation, claimed and live flags, readers inside a lookup)
/// and a weak reference to the object. A lookup is lock-free: an atomic add enters the slot, the generation and
/// live flag decide, the weak reference is read, an atomic subtract leaves. Unregistering bumps the generation
/// and clears the live flag, so old tokens miss; the weak reference is written only by the next `register`, which
/// claims a slot only when no reader is inside it. No call takes a lock or makes a syscall, so a callback on any
/// thread (an FSEvents queue, an event tap on the main run loop, a render thread) can use it.
// concurrency-allow: what synchronizes it: each slot's state word changes only by an acquire-release compare-exchange
// (register claims a free slot) or a release fetch-or / fetch-sub (publish live, leave a lookup); a lookup enters with an
// acquire fetch-add and reads the weak reference only after it sees the live bit, so the register thread's write of the
// reference happens-before that read. The reference is written only while the slot is claimed with no reader inside it.
@safe
public final class CallbackRegistry<Target: AnyObject & Sendable>: @unchecked Sendable { // crash-allow: every state word is reached only through hardware atomic operations, and a slot's weak reference is written only by the register call that claimed the slot with no reader inside and read only by lookups that entered while it was live (see the type's documentation)
    /// One slot's object, weakly: an owner that dies without unregistering leaves a slot whose lookups miss.
    private struct WeakTarget {
        weak var target: Target?
    }

    /// The number of slots: the most entries registered at once.
    public let capacity: Int
    private let states: UnsafeMutablePointer<UInt64>
    private let targets: UnsafeMutablePointer<WeakTarget>
    /// [0]: tokens ignored (``ignoredCount``); [1]: where the next `register` starts looking.
    private let counters: UnsafeMutablePointer<UInt64>

    /// Makes a registry of `capacity` slots (memory: 16 bytes a slot, allocated now).
    public init(capacity: UInt16) {
        let count = Int(capacity)
        let states = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: count)
        unsafe states.initialize(repeating: 0, count: count)
        let targets = unsafe UnsafeMutablePointer<WeakTarget>.allocate(capacity: count)
        unsafe targets.initialize(repeating: WeakTarget(), count: count)
        let counters = unsafe UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
        unsafe counters.initialize(repeating: 0, count: 2)
        self.capacity = count
        unsafe self.states = states
        unsafe self.targets = targets
        unsafe self.counters = counters
    }

    deinit {
        unsafe states.deinitialize(count: capacity)
        unsafe states.deallocate()
        unsafe targets.deinitialize(count: capacity)
        unsafe targets.deallocate()
        unsafe counters.deinitialize(count: 2)
        unsafe counters.deallocate()
    }

    /// Adds `target` and returns its token, the context to give C. Unregister the token once C can no longer
    /// call back with it (after the stream or tap is invalidated).
    public func register(_ target: Target) throws(CallbackRegistryError) -> CallbackToken {
        guard capacity > 0 else { throw .full(capacity: capacity) }
        // SAFETY: `counters` holds two words for the registry's lifetime.
        let start = unsafe cmux_safe_atomic_fetch_add_relaxed(counters + 1, 1)
        for step in 0 ..< capacity {
            let index = Int(truncatingIfNeeded: (start &+ UInt64(truncatingIfNeeded: step)) % UInt64(truncatingIfNeeded: capacity))
            // SAFETY: index < capacity, the words `states` holds for the registry's lifetime.
            let state = unsafe states + index
            let observed = unsafe cmux_safe_atomic_load_acquire(state)
            // A slot is free when it is neither claimed nor live and no lookup is inside it (one that entered
            // before the last unregister may still be reading the weak reference this would overwrite).
            guard observed & (readerMask | claimedBit | liveBit) == 0,
                  unsafe cmux_safe_atomic_compare_exchange(state, observed, observed | claimedBit) else { continue }
            // SAFETY: the claim above makes this the slot's only writer, and lookups read the reference only
            // after the release below shows the live flag.
            unsafe targets[index].target = target
            _ = unsafe cmux_safe_atomic_fetch_or_release(state, liveBit)
            return CallbackToken(generation: UInt32(truncatingIfNeeded: observed >> 32), index: index)
        }
        throw .full(capacity: capacity)
    }

    /// Removes `token`'s entry: from now on its callbacks are ignored and counted, and the slot can be reused.
    /// Returns false (and counts it) for a token that names no live entry, such as one already unregistered.
    @discardableResult
    public func unregister(_ token: CallbackToken) -> Bool {
        guard let index = token.index(below: capacity) else {
            countIgnored()
            return false
        }
        // SAFETY: index < capacity (above).
        let state = unsafe states + index
        var observed = unsafe cmux_safe_atomic_load_acquire(state)
        while UInt32(truncatingIfNeeded: observed >> 32) == token.generation, observed & liveBit != 0 {
            // The next generation, no flags, the readers inside kept: the weak reference stays until the next
            // register replaces it, since a lookup that entered before this may still be reading it.
            let freed = UInt64(token.generation &+ 1) << 32 | observed & readerMask
            if unsafe cmux_safe_atomic_compare_exchange(state, observed, freed) { return true }
            observed = unsafe cmux_safe_atomic_load_acquire(state)
        }
        countIgnored()
        return false
    }

    /// The object of `token`'s entry, or nil (counted in ``ignoredCount``) when the token names no live entry or
    /// its object is gone. Lock-free: two atomic adds and a weak load.
    // perf-hot: 50ns callback-registry-lookup
    public func target(for token: CallbackToken) -> Target? {
        guard let index = token.index(below: capacity) else {
            countIgnored()
            return nil
        }
        // SAFETY: index < capacity (above).
        let state = unsafe states + index
        let observed = unsafe cmux_safe_atomic_fetch_add_acquire(state, 1)
        // SAFETY: while this lookup is counted in the slot's readers, no register can claim the slot, so the
        // reference is not written during the read; the acquire above sees the write that made it live.
        let found: Target?
        if UInt32(truncatingIfNeeded: observed >> 32) == token.generation, observed & liveBit != 0 {
            found = unsafe targets[index].target
        } else {
            found = nil
        }
        _ = unsafe cmux_safe_atomic_fetch_sub_release(state, 1)
        if found == nil { countIgnored() }
        return found
    }

    /// ``target(for:)`` for the context a C callback received.
    @safe public func target(forContext context: UnsafeMutableRawPointer?) -> Target? {
        target(for: CallbackToken(context: unsafe context))
    }

    /// The callbacks and unregisters whose token named no live entry: a callback after its owner went away, a
    /// second unregister, a forged context. Monotonic for the registry's lifetime.
    public var ignoredCount: UInt64 {
        // SAFETY: `counters` holds two words for the registry's lifetime.
        unsafe cmux_safe_atomic_load_relaxed(counters)
    }

    private func countIgnored() {
        // SAFETY: as in `ignoredCount`.
        _ = unsafe cmux_safe_atomic_fetch_add_relaxed(counters, 1)
    }
}
