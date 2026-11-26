import Foundation
import Synchronization

/// Waits that run on (or hold up) the main actor, each with a bound and a way to end it.
/// The hang watchdog's thread cancels any wait older than its bound, so a known wait never
/// becomes an endless freeze: the waiter gets its "gave up" answer instead (sign-out's
/// `BoundedWait` is the first one wired).
///
/// `cancel` runs on the watchdog thread, never the main thread, at most once, and must be
/// thread-safe. A wait that ends by itself calls ``Registration/finish()``; finishing after a
/// cancel is fine.
public final class MainThreadWaitRegistry: Sendable {
    public static let shared = MainThreadWaitRegistry()

    struct Entry {
        var label: String
        var deadline: UInt64
        var cancel: @Sendable () -> Void
    }

    private let entries = Mutex<(next: UInt64, waits: [UInt64: Entry])>((0, [:]))
    /// Wakes the watchdog thread to read a new, earlier deadline (set by the watchdog).
    private let waker = Mutex<(@Sendable () -> Void)?>(nil)
    let uptime: @Sendable () -> UInt64

    public init() {
        uptime = { MainThreadHangWatchdog.now() }
    }

    init(uptime: @escaping @Sendable () -> UInt64) {
        self.uptime = uptime
    }

    /// One registered wait; ``finish()`` when it ends by itself.
    public struct Registration: Sendable {
        let id: UInt64
        let registry: MainThreadWaitRegistry

        public func finish() { registry.remove(id) }
    }

    /// Registers a wait that must end within `bound`; `cancel` ends it (off the main thread).
    public func register(_ label: String, bound: Duration, cancel: @escaping @Sendable () -> Void) -> Registration {
        let deadline = uptime() &+ MainThreadHangWatchdog.nanos(bound, minimum: 1)
        let id = entries.withLock { state in
            let id = state.next
            state.next &+= 1
            state.waits[id] = Entry(label: label, deadline: deadline, cancel: cancel)
            return id
        }
        waker.withLock { $0 }?()
        return Registration(id: id, registry: self)
    }

    func remove(_ id: UInt64) {
        _ = entries.withLock { $0.waits.removeValue(forKey: id) }
    }

    /// How many waits are registered now.
    public var count: Int { entries.withLock { $0.waits.count } }

    /// The earliest deadline, nil with nothing registered.
    func nextDeadline() -> UInt64? {
        entries.withLock { $0.waits.values.map(\.deadline).min() }
    }

    /// Removes and cancels every wait past its deadline (the watchdog thread). Returns their labels.
    @discardableResult
    func cancelExpired(now: UInt64) -> [String] {
        let expired = entries.withLock { state -> [Entry] in
            let due = state.waits.filter { $0.value.deadline <= now }
            for id in due.keys { state.waits[id] = nil }
            return Array(due.values)
        }
        // Outside the lock: a cancel may register or finish another wait.
        for entry in expired { entry.cancel() }
        return expired.map(\.label)
    }

    func setWaker(_ wake: (@Sendable () -> Void)?) {
        waker.withLock { $0 = wake }
    }
}
