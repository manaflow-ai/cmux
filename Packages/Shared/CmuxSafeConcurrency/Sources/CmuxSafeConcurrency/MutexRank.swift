#if DEBUG
#if canImport(Darwin)
internal import Darwin
#elseif canImport(Glibc)
internal import Glibc
#elseif canImport(Musl)
internal import Musl
#endif
#endif

/// A lock's place in its process's lock order, for ``Mutex/init(_:rank:)``. A thread may wait for a ranked
/// mutex only when its ``order`` is after the order of every ranked mutex the thread already holds; a wait at an
/// order equal to or before a held one is a lock inversion, which two threads can turn into a deadlock.
///
/// In Debug builds each thread keeps the ranks it holds, and a ``Mutex/withLock(_:)`` that would invert them
/// stops the process before it waits, with a message that names both locks. A ``Mutex/withLockIfAvailable(_:)``
/// cannot wait, so it is recorded but not checked. Release builds keep no rank and check nothing: the rank is
/// dropped at init.
///
/// This is Chromium's `CheckedLock` (base/task/common/checked_lock.h, checked_lock_impl.cc: a thread-local list
/// of the locks the thread holds, checked on each acquisition when DCHECKs are on), with ranks in place of
/// predecessors as cmux-tui's `RankedMutex` has them (cmux-tui/crates/cmux-tui-core/src/lock_rank.rs).
public struct MutexRank: Sendable {
    /// The order a thread takes ranks in: lower first (outer), higher later (inner).
    public let order: UInt32
    /// The lock's name in an inversion report (`"daemon.line-transport.state"`).
    public let name: StaticString

    /// The order of a ``leaf(_:)`` rank: after every other.
    public static let leafOrder = UInt32.max

    /// Makes the rank of the lock `name` at `order`.
    public init(_ name: StaticString, order: UInt32) {
        self.name = name
        self.order = order
    }

    /// The rank of a lock that never waits for another ranked lock while it is held: it ranks after every
    /// other rank, so two leaf locks never nest either.
    public static func leaf(_ name: StaticString) -> MutexRank {
        MutexRank(name, order: leafOrder)
    }

    /// The held rank that taking `self` while holding `held` inverts: the one with the highest order when that
    /// order is not before `self`'s; nil when taking `self` keeps the order.
    public func inversion(holding held: [MutexRank]) -> MutexRank? {
        guard let inner = held.max(by: { $0.order < $1.order }), inner.order >= order else { return nil }
        return inner
    }

    /// The inversion report of taking `self` while holding `inner` (``inversion(holding:)``): both locks
    /// and their orders.
    public func inversionMessage(holding inner: MutexRank) -> String {
        "lock order violation: acquiring \(name) (rank \(order)) while this thread holds \(inner.name) "
            + "(rank \(inner.order)); a thread takes ranked locks in ascending order only"
    }
}

#if DEBUG
extension MutexRank {
    /// Before a ``Mutex`` waits for its lock: stops the process when the wait inverts the ranks this thread
    /// holds, then records `self` as held (until ``didUnlock()``).
    @usableFromInline
    func willLock() {
        guard let held = HeldMutexRanks.current() else { return }
        if let inner = inversion(holding: held.ranks) {
            assertionFailure(inversionMessage(holding: inner))
        }
        held.ranks.append(self)
    }

    /// A ``Mutex`` took its lock without waiting (a try-lock): records `self` as held, unchecked.
    @usableFromInline
    func didTryLock() {
        HeldMutexRanks.current()?.ranks.append(self)
    }

    /// A ``Mutex`` released its lock: `self` is no longer held. Locks are scoped (`withLock`), so it is the
    /// rank recorded last.
    @usableFromInline
    func didUnlock() {
        guard let held = HeldMutexRanks.current() else { return }
        let last = held.ranks.popLast()
        assert(last?.order == order, "\(name) released while this thread holds \(last?.name ?? "no ranked lock")")
    }
}

/// The ranks one thread holds (Debug only), innermost last; in a thread-specific slot that frees it when the
/// thread exits.
final class HeldMutexRanks {
    var ranks: [MutexRank] = []

    /// The thread-specific key; nil when the process has no key left (nothing is checked then).
    private static let key: pthread_key_t? = {
        var key = pthread_key_t()
        // SAFETY: pthread_key_create writes one key into `key`, a local live for the call; the destructor
        // releases the +1 that current() stored for the exiting thread.
        return unsafe pthread_key_create(&key) { HeldMutexRanks.threadExited($0) } == 0 ? key : nil
    }()

    /// The calling thread's held ranks, made on its first ranked lock.
    static func current() -> HeldMutexRanks? {
        guard let key else { return nil }
        // SAFETY: the thread's value for `key` is nil or the object current() retained for this thread below,
        // released only by threadExited when the thread ends.
        if let raw = unsafe pthread_getspecific(key) {
            return unsafe Unmanaged<HeldMutexRanks>.fromOpaque(raw).takeUnretainedValue()
        }
        let held = HeldMutexRanks()
        let retained = unsafe Unmanaged.passRetained(held)
        // SAFETY: stores the +1 for this thread; threadExited releases it.
        guard unsafe pthread_setspecific(key, retained.toOpaque()) == 0 else {
            unsafe retained.release()
            return nil
        }
        return held
    }

    /// The key's destructor: releases the exiting thread's held ranks.
    private static func threadExited(_ raw: UnsafeMutableRawPointer?) {
        guard let raw = unsafe raw else { return }
        // SAFETY: `raw` is the +1 current() stored for this thread; the thread is ending, nothing reads it after.
        unsafe Unmanaged<HeldMutexRanks>.fromOpaque(raw).release()
    }
}
#endif
