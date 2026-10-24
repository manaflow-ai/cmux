/// A dictionary from many keys to one value each that also answers the reverse question, which keys
/// map to a value, in O(that answer) instead of a scan of every entry.
///
/// Both directions change together on every write, so they never drift: a write moves the key from
/// its old value's set to the new one, a removal (`index[key] = nil`, ``removeValue(forKey:)``)
/// drops it, and a value whose last key goes is no value any more.
///
/// ```swift
/// var storeKeys = ManyToOneIndex<String, String>()  // store tab id -> provider key
/// storeKeys["provisional-1"] = "page:home.tab:1"
/// storeKeys["surface:7"] = "page:home.tab:1"        // the store's tab replaced it
/// storeKeys.keys(for: "page:home.tab:1")           // ["provisional-1", "surface:7"]
/// ```
public struct ManyToOneIndex<Key: Hashable, Value: Hashable> {
    private var forward: [Key: Value] = [:]
    private var reverse: [Value: Set<Key>] = [:]

    /// An empty index.
    public init() {}

    /// The value `key` maps to; setting it (nil removes the key) updates the reverse side too.
    public subscript(key: Key) -> Value? {
        get { forward[key] }
        set {
            if let newValue { insert(newValue, for: key) } else { removeValue(forKey: key) }
        }
    }

    /// Removes `key` from both directions.
    /// - Returns: the value it mapped to, nil when it mapped to none.
    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        guard let old = forward.removeValue(forKey: key) else { return nil }
        detach(key, from: old)
        return old
    }

    /// The keys that map to `value` (empty when none does). O(the keys returned).
    public func keys(for value: Value) -> Set<Key> { reverse[value] ?? [] }

    /// Whether any key maps to `value`. O(1).
    public func contains(value: Value) -> Bool { reverse[value] != nil }

    /// Every distinct value some key maps to.
    public var values: Dictionary<Value, Set<Key>>.Keys { reverse.keys }

    private mutating func insert(_ value: Value, for key: Key) {
        if let old = forward.updateValue(value, forKey: key) {
            guard old != value else { return }
            detach(key, from: old)
        }
        reverse[value, default: []].insert(key)
    }

    private mutating func detach(_ key: Key, from value: Value) {
        reverse[value]?.remove(key)
        if reverse[value]?.isEmpty == true { reverse[value] = nil }
    }
}
