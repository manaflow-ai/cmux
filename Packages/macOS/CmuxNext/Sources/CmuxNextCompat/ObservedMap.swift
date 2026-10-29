public import Observation

/// A dictionary whose entries are observed one key at a time
/// (perf-speed-of-light.md I2: a read of a collection is a read of every
/// element). Reading `map[key]` observes that key only, so a write of
/// another key re-runs nothing that read this one; a write of an equal
/// value notifies nobody. A reader that needs every entry (`keys`,
/// `entries`) observes `keysRevision` and the entries it reads.
///
/// The slot of a key is made on its first read or write (an unobserved
/// write), so a reader that looks before the key has a value still hears
/// the first one. Slots of removed keys are kept until `compact()` (or a
/// rewrite of the key), so readers of a removed key hear it come back.
@MainActor @Observable
public final class ObservedMap<Key: Hashable & Sendable, Value: Equatable> {
    @MainActor @Observable
    final class Slot {
        var value: Value?
        init() {}
        // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14: the
        // implicit isolated deinit crashes swift-frontend 6.3.3's Release inliner (EarlyPerfInliner,
        // isCallerAndCalleeLayoutConstraintsCompatible) on its deallocating deinit. This one touches nothing.
        nonisolated deinit {}
    }

    @ObservationIgnored private var slots: [Key: Slot] = [:]
    /// The keys with a value, unobserved (`keys` observes `keysRevision` instead).
    @ObservationIgnored private var present: Set<Key> = []
    /// Bumped when a key gets its first value or loses it.
    public private(set) var keysRevision: UInt64 = 0

    public init() {}

    // A main-actor generic class needs a nonisolated deinit while the package targets macOS 14: the
    // implicit isolated deinit crashes swift-frontend 6.3.3's Release inliner (EarlyPerfInliner,
    // isCallerAndCalleeLayoutConstraintsCompatible) on its deallocating deinit. This one touches nothing.
    nonisolated deinit {}

    private func slot(_ key: Key) -> Slot {
        if let slot = slots[key] { return slot }
        let slot = Slot()
        slots[key] = slot
        return slot
    }

    /// The value of `key`; observes `key` only.
    public subscript(key: Key) -> Value? {
        get { slot(key).value }
        set {
            // A removal of a key nobody read or wrote makes no slot.
            guard newValue != nil || slots[key] != nil else { return }
            let slot = slot(key)
            guard slot.value != newValue else { return }
            if (slot.value == nil) != (newValue == nil) {
                keysRevision &+= 1
                if newValue == nil { present.remove(key) } else { present.insert(key) }
            }
            slot.value = newValue
        }
    }

    /// The value of `key`, or `fallback` when it has none; observes `key` only.
    public subscript(key: Key, default fallback: @autoclosure () -> Value) -> Value {
        get { slot(key).value ?? fallback() }
        set { self[key] = newValue }
    }

    /// The keys with a value (observes the key set, not the values).
    public var keys: [Key] {
        _ = keysRevision
        return Array(present)
    }

    /// Every key with its value (observes the key set and every value).
    public var entries: [(key: Key, value: Value)] {
        _ = keysRevision
        return slots.compactMap { key, slot in slot.value.map { (key, $0) } }
    }

    /// Removes and returns the value of `key`.
    @discardableResult
    public func removeValue(forKey key: Key) -> Value? {
        let old = slots[key]?.value
        self[key] = nil
        return old
    }

    /// Drops the slots of keys without a value that nobody can be waiting on
    /// for `keep` false (a pane or tab that is gone).
    public func compact(keeping keep: (Key) -> Bool) {
        for (key, slot) in slots where !keep(key) {
            if slot.value != nil {
                keysRevision &+= 1
                present.remove(key)
                slot.value = nil
            }
            slots[key] = nil
        }
    }
}
