/// One open hang-watch scope (Chrome's `WatchHangsInScope`). Not copyable: it closes exactly once, with
/// ``close()`` or when it goes away, and restores the enclosing scope's deadline in its slot. Not
/// `Sendable`: the slot's nesting belongs to the thread (or the lane job) that opened the scope, so the
/// scope closes there too, as Chrome's scope is bound to its thread. It keeps its ``HangWatch`` (and so the slot
/// it restores) alive until it closes.
public struct HangWatchScope: ~Copyable {
    /// The slot the scope watches.
    let registration: HangWatch.Registration
    /// The packed deadline the scope replaced (the enclosing scope's, with its flags), restored at close.
    let previousDeadline: UInt64
    /// The slot's address; 0 when the registration has no slot (the scope does nothing).
    let slotAddress: UInt
    /// The slot table, held until the scope closes: `slotAddress` points into memory it frees at deinit.
    let owner: HangWatch?

    init(registration: HangWatch.Registration, previousDeadline: UInt64, slotAddress: UInt, owner: HangWatch?) {
        self.registration = registration
        self.previousDeadline = previousDeadline
        self.slotAddress = slotAddress
        self.owner = owner
    }

    /// Closes the scope now (before the end of the code block that holds it): consuming it ends the
    /// value here, so its deinit restores the deadline, once. (No `discard self`: the scope holds its
    /// ``HangWatch``, which is not trivially destroyed.)
    public consuming func close() {}

    /// Puts `previousDeadline` back in the slot: the one place a scope restores, at close or when it goes away.
    deinit {
        owner?.close(slotAddress: slotAddress, registration: registration, previous: previousDeadline)
    }
}
