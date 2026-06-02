import Foundation

/// An insertion-ordered, string-keyed record.
///
/// Used for the workspace passed to `render-row` and for any script-built record
/// (`(record :a 1 :b 2)`). Keys preserve insertion order so display and
/// iteration are stable; a `:title` key is stored under the bare string
/// `"title"`.
public struct LispMap {
    /// Keys in insertion order.
    public private(set) var keys: [String]
    private var storage: [String: LispValue]

    /// An empty record.
    public init() {
        keys = []
        storage = [:]
    }

    /// A record built from ordered key/value pairs. Later pairs with a repeated
    /// key overwrite earlier values while keeping the first key position.
    public init(_ pairs: [(String, LispValue)]) {
        keys = []
        storage = [:]
        for (k, v) in pairs { self[k] = v }
    }

    /// Reads or writes a value by key. Setting nil removes the key.
    public subscript(_ key: String) -> LispValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { keys.append(key) }
                storage[key] = newValue
            } else {
                if storage[key] != nil { keys.removeAll { $0 == key } }
                storage[key] = nil
            }
        }
    }

    /// The key/value pairs in insertion order.
    public var pairs: [(String, LispValue)] { keys.map { ($0, storage[$0]!) } }
}

extension LispMap: Equatable {
    public static func == (lhs: LispMap, rhs: LispMap) -> Bool {
        guard lhs.keys == rhs.keys else { return false }
        for k in lhs.keys where lhs[k] != rhs[k] { return false }
        return true
    }
}
