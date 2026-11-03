// cmux: a key for objc_getAssociatedObject without a mutable global. Not a vendored file.

/// A unique key for `objc_getAssociatedObject` / `objc_setAssociatedObject`: the address of one object
/// that a global `let` keeps for the life of the process.
///
/// The usual key, `private var key: UInt8 = 0` passed as `&key`, is a mutable global, so Swift 6 needs
/// `nonisolated(unsafe)` on it. The runtime compares only the key's address, so an immutable `Sendable`
/// object serves with no unsafe annotation:
///
/// ```swift
/// private let redrawKey = AssociationKey()
/// objc_getAssociatedObject(field, redrawKey.pointer)
/// ```
final class AssociationKey: Sendable {
    /// The key's address: the value the Objective-C runtime compares. Stable while the object lives.
    var pointer: UnsafeRawPointer { UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()) }
}
