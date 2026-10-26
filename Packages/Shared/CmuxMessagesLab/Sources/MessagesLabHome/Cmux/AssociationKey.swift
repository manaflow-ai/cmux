// cmux: a key for objc_getAssociatedObject without a mutable global. Not a vendored file.
import ObjectiveC

/// A unique key for an Objective-C associated object: the address of one object that a global `let`
/// keeps for the life of the process.
///
/// The usual key, `private var key: UInt8 = 0` passed as `&key`, is a mutable global, so Swift 6 needs
/// `nonisolated(unsafe)` on it. The runtime compares only the key's address, so an immutable `Sendable`
/// object serves with no unsafe annotation, and the two runtime calls (which take the key as a raw
/// pointer) are made here only, with their SAFETY argument (p10-stability-073):
///
/// ```swift
/// private let redrawKey = AssociationKey()
/// redrawKey.value(on: field) as? ComposeInlineRedraw
/// ```
final class AssociationKey: Sendable {
    /// The value associated with `object` under this key, or nil.
    func value(on object: Any) -> Any? {
        // SAFETY: the key is this object's address, valid while it lives (a global `let` keeps every key for the
        // process); the runtime only compares it and never reads or writes memory through it.
        unsafe objc_getAssociatedObject(object, pointer)
    }

    /// Associates `value` with `object` under this key, retained, nonatomic (nil removes it).
    func set(_ value: Any?, on object: Any) {
        // SAFETY: as `value(on:)`: the key's address is only compared.
        unsafe objc_setAssociatedObject(object, pointer, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The key's address: the value the Objective-C runtime compares. Stable while the object lives.
    private var pointer: UnsafeRawPointer {
        // SAFETY: the address of `self`, unretained: it is only compared (above), never dereferenced.
        unsafe UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }
}
