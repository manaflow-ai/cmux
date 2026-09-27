public import Foundation

/// Writes that stay silent when the stored value already matches.
///
/// `UserDefaults.set(_:forKey:)` and `removeObject(forKey:)` post
/// `UserDefaults.didChangeNotification` on every call, including writes that
/// store an identical value and removals of absent keys. That notification runs
/// every defaults observer in the process on the writing thread, including
/// SwiftUI's `@AppStorage` observer, which takes SwiftUI's global update lock
/// and so contends with main-thread rendering. Periodic writers (session
/// autosave) use these helpers so steady-state saves post nothing.
///
/// The comparison reads through the normal search list, so a matching value in
/// the argument or registration domain also counts as unchanged.
extension UserDefaults {
    /// Stores `value` for `key` unless the current value is byte-for-byte equal.
    /// - Returns: `true` when a write happened.
    @discardableResult
    public func setIfChanged(_ value: Data, forKey key: String) -> Bool {
        if data(forKey: key) == value { return false }
        set(value, forKey: key)
        return true
    }

    /// Stores `value` for `key` unless the current value is the same Boolean.
    /// - Returns: `true` when a write happened.
    @discardableResult
    public func setIfChanged(_ value: Bool, forKey key: String) -> Bool {
        if let current = object(forKey: key) as? Bool, current == value { return false }
        set(value, forKey: key)
        return true
    }

    /// Removes `key` only when a value is present.
    /// - Returns: `true` when a removal happened.
    @discardableResult
    public func removeObjectIfPresent(forKey key: String) -> Bool {
        guard object(forKey: key) != nil else { return false }
        removeObject(forKey: key)
        return true
    }
}
