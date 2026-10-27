/// Sets a crash key for the life of the value and puts the value it replaced back when it ends (Chrome's
/// `ScopedCrashKeyString`, components/crash/core/common/crash_key.h). Noncopyable, so it ends once.
///
/// ```swift
/// let scope = ScopedCrashKey(keys, .inCEFPump, 1)
/// pump()
/// scope.end()                                  // or at the end of the scope
/// ```
public struct ScopedCrashKey: ~Copyable {
    private let page: CrashKeyPage
    private let slot: CrashKeySlot
    private let outer: UInt64

    /// Sets `slot` to `value` on `page`.
    public init(_ page: CrashKeyPage, _ slot: CrashKeySlot, _ value: UInt64) {
        self.page = page
        self.slot = slot
        outer = page.value(slot)
        page.set(slot, value)
    }

    /// Puts the outer value back now.
    public consuming func end() {}

    deinit {
        page.set(slot, outer)
    }
}
