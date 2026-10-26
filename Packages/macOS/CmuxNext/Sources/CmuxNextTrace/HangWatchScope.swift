/// One open hang-watch scope (Chrome's `WatchHangsInScope`). Not copyable: it closes exactly once, with
/// ``close()`` or when it goes away, and restores the enclosing scope's deadline in its slot. Not
/// `Sendable`: the slot's nesting belongs to the thread (or the lane job) that opened the scope, so the
/// scope closes there too, as Chrome's scope is bound to its thread. It must not outlive its ``HangWatch``.
public struct HangWatchScope: ~Copyable {
    /// The slot the scope watches.
    let registration: HangWatch.Registration
    /// The packed deadline the scope replaced (the enclosing scope's, with its flags), restored at close.
    let previousDeadline: UInt64
    /// The slot's address; 0 when the registration has no slot (the scope does nothing).
    let slotAddress: UInt
    /// The slot table, not retained (no reference-count traffic on the scope path).
    let owner: Unmanaged<HangWatch>?

    init(registration: HangWatch.Registration, previousDeadline: UInt64, slotAddress: UInt, owner: Unmanaged<HangWatch>?) {
        self.registration = registration
        self.previousDeadline = previousDeadline
        self.slotAddress = slotAddress
        self.owner = owner
    }

    /// Closes the scope now (before the end of the code block that holds it). It restores the deadline,
    /// then discards itself, so the deinit does not restore a second time.
    public consuming func close() {
        restore()
        discard self
    }

    deinit {
        restore()
    }

    /// Puts `previousDeadline` back in the slot: the one place close and deinit restore.
    private func restore() {
        guard let owner else { return }
        owner._withUnsafeGuaranteedRef {
            $0.close(slotAddress: slotAddress, registration: registration, previous: previousDeadline)
        }
    }
}
