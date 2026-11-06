/// The identity of an agent tab includes the daemon that lists it. Forked and SSH machines may
/// legitimately reuse a durable tab id, so a bare id is not a complete key for AgentTabs state.
public struct AgentTabKey: Hashable, Sendable {
    public let machine: String
    public let key: String

    public init(machine: String, key: String) {
        self.machine = machine
        self.key = key
    }

    /// The launch-wake file predates machine-qualified state. Encode only colliding ids so old
    /// bare keys remain readable while relaunch can distinguish two machines' same chat.
    public func relaunchStorageKey(duplicateIDs: Set<String>) -> String {
        guard !machine.isEmpty, duplicateIDs.contains(key) else { return key }
        return machine + "\u{0}" + key
    }

    public var relaunchKeyCandidates: [String] {
        machine.isEmpty ? [key] : [machine + "\u{0}" + key, key]
    }

    public init(relaunchStorageKey storageKey: String) {
        guard let separator = storageKey.firstIndex(of: "\u{0}"), separator > storageKey.startIndex else {
            self.init(machine: "", key: storageKey)
            return
        }
        self.init(machine: String(storageKey[..<separator]), key: String(storageKey[storageKey.index(after: separator)...]))
    }
}

/// AgentTabs state keyed by machine and tab id. The String subscript is retained for old
/// single-machine callers and returns a value only when that id is unambiguous.
public struct AgentTabMap<Value>: Sequence {
    private var storage: [AgentTabKey: Value] = [:]

    public typealias Element = (key: String, value: Value)
    public typealias Iterator = IndexingIterator<[Element]>

    public init() {}

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }
    public var keys: [String] { storage.keys.map(\.key).unique() }
    public var values: [Value] { Array(storage.values) }
    public var entries: [(key: AgentTabKey, value: Value)] { storage.map { (key: $0.key, value: $0.value) } }
    public static func duplicateIDs(_ keys: [AgentTabKey]) -> Set<String> {
        var counts: [String: Int] = [:]
        keys.forEach { counts[$0.key, default: 0] += 1 }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }
    public func relaunchEntries(_ duplicateIDs: Set<String>) -> [String: Value] {
        entries.reduce(into: [String: Value]()) { $0[$1.key.relaunchStorageKey(duplicateIDs: duplicateIDs)] = $1.value }
    }
    public var bare: [String: Value] {
        storage.reduce(into: [:]) { result, entry in
            guard result[entry.key.key] == nil else { return }
            result[entry.key.key] = entry.value
        }
    }
    public func makeIterator() -> Iterator { storage.map { (key: $0.key.key, value: $0.value) }.makeIterator() }

    public subscript(_ key: AgentTabKey) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                storage[key] = newValue
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }

    public subscript(_ key: String) -> Value? {
        get {
            let matches = storage.filter { $0.key.key == key }
            guard matches.count == 1 else { return storage[AgentTabKey(machine: "", key: key)] }
            return matches.first?.value
        }
        set {
            let matches = storage.keys.filter { $0.key == key }
            if let existing = matches.count == 1 ? matches[0] : nil {
                self[existing] = newValue
            } else {
                self[AgentTabKey(machine: "", key: key)] = newValue
            }
        }
    }

    public func first(where predicate: ((key: String, value: Value)) throws -> Bool) rethrows -> (key: String, value: Value)? {
        for (key, value) in storage where try predicate((key: key.key, value: value)) {
            return (key: key.key, value: value)
        }
        return nil
    }

    public func map<T>(_ transform: ((key: String, value: Value)) throws -> T) rethrows -> [T] {
        try storage.map { try transform((key: $0.key.key, value: $0.value)) }
    }

    public mutating func removeValue(forKey key: AgentTabKey) -> Value? { storage.removeValue(forKey: key) }

    public mutating func removeValue(forKey key: String) -> Value? {
        let matches = storage.keys.filter { $0.key == key }
        guard matches.count == 1, let match = matches.first else { return storage.removeValue(forKey: AgentTabKey(machine: "", key: key)) }
        return storage.removeValue(forKey: match)
    }

    public func filter(_ isIncluded: ((key: String, value: Value)) throws -> Bool) rethrows -> AgentTabMap<Value> {
        var result = AgentTabMap<Value>()
        for (key, value) in storage where try isIncluded((key: key.key, value: value)) { result[key] = value }
        return result
    }
}

private extension Collection where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
