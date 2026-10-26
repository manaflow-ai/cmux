import ObjectiveC

/// One typed Objective-C associated-object slot: `value(on:)` and
/// `set(_:on:)` keep a `Value` on any object, retained with it (Chromium's
/// base::SupportsUserData does the same job with a typed key per kind of
/// data, base/supports_user_data.h). The key is this object's own address,
/// so a slot needs no mutable global and no pointer at its call sites; keep
/// each slot in a `static let`, which lives as long as the process.
///
/// ```swift
/// private static let clocks = ObjectAssociation<MotionClock>()
/// clocks.set(clock, on: window)
/// ```
public nonisolated final class ObjectAssociation<Value>: Sendable {
    public init() {}

    /// The runtime's key: this slot's address, unique and stable while the slot lives.
    private var key: UnsafeRawPointer {
        // SAFETY: the address only names the slot; the runtime compares it and never reads through it.
        unsafe UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }

    /// The value on `owner`, nil when none is set (or another type is).
    public func value(on owner: AnyObject) -> Value? {
        // SAFETY: `key` is this slot's live address (see `key`).
        unsafe objc_getAssociatedObject(owner, key) as? Value
    }

    /// Sets `value` on `owner` (nil removes it), retained until `owner` deallocates or a later set.
    public func set(_ value: Value?, on owner: AnyObject) {
        // SAFETY: `key` is this slot's live address (see `key`).
        unsafe objc_setAssociatedObject(owner, key, value.map { $0 as Any }, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
