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

/// AgentTabs state keyed by machine and tab id. It has no bare-id access: a tab id alone names
/// no tab once two machines list the same one, so every read and write says which machine.
public struct AgentTabMap<Value>: Sequence {
    private var storage: [AgentTabKey: Value] = [:]
    /// The machines that hold each tab id: "which machines have this id" (`keys(ofTab:)`) is asked on
    /// every key press and tab draw with an id alone, so it reads this, never every key.
    private var machines: [String: Set<String>] = [:]

    public typealias Element = (key: AgentTabKey, value: Value)
    public typealias Iterator = IndexingIterator<[Element]>

    public init() {}

    public var isEmpty: Bool { storage.isEmpty }
    public var count: Int { storage.count }
    public var keys: [AgentTabKey] { Array(storage.keys) }
    public var values: [Value] { Array(storage.values) }
    public var entries: [(key: AgentTabKey, value: Value)] { storage.map { (key: $0.key, value: $0.value) } }
    public static func duplicateIDs(_ keys: [AgentTabKey]) -> Set<String> {
        // Distinct machines only: one tab listed twice (its page and its tree's row) is not a duplicate.
        var counts: [String: Int] = [:]
        Set(keys).forEach { counts[$0.key, default: 0] += 1 }
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }
    public func relaunchEntries(_ duplicateIDs: Set<String>) -> [String: Value] {
        entries.reduce(into: [String: Value]()) { $0[$1.key.relaunchStorageKey(duplicateIDs: duplicateIDs)] = $1.value }
    }
    public func makeIterator() -> Iterator { entries.makeIterator() }

    public subscript(_ key: AgentTabKey) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { machines[key.key, default: []].insert(key.machine) }
            } else {
                _ = removeValue(forKey: key)
            }
        }
    }

    /// The keys of tab id `key` on every machine that has one.
    public func keys(ofTab key: String) -> [AgentTabKey] { machines[key]?.map { AgentTabKey(machine: $0, key: key) } ?? [] }

    /// Whether a key here can be what an `aliases` resolution of `key` lands on: its own key, the alias `key` has on
    /// that key's machine, a key whose alias is `key`, or the machine-less key `key`'s only alias names. O(count + aliases),
    /// and nothing else is read: a tab no entry answers to (a terminal, a browser tab) is answered without the
    /// walk of every listed chat that `AgentTabStore.tabKey` does (3-4.6 s main-thread hangs in a workspace
    /// hibernation pass, which asks this for every tab of every workspace; hang files 2026-11-09).
    public func hasKey(answering key: String, aliases: AgentTabMap<String>) -> Bool {
        var resolved: String?  // `key` through its only alias, read once and only for a machine-less entry
        return storage.keys.contains { made in
            if made.key == key || aliases[AgentTabKey(machine: made.machine, key: key)] == made.key
                || aliases[made] == key { return true }
            guard made.machine.isEmpty else { return false }
            let target = resolved ?? (aliases.onlyKey(ofTab: key).flatMap { aliases[$0] } ?? key)
            resolved = target
            return made.key == target
        }
    }

    /// The values by tab id of the ids exactly one machine has (an id two machines share names neither).
    public var unambiguousIDs: [String: Value] {
        let shared = Self.duplicateIDs(Array(storage.keys))
        return storage.reduce(into: [:]) { if !shared.contains($1.key.key) { $0[$1.key.key] = $1.value } }
    }

    /// The one key of tab id `key`; nil when no machine or more than one has it.
    public func onlyKey(ofTab key: String) -> AgentTabKey? {
        guard let holders = machines[key], holders.count == 1, let machine = holders.first else { return nil }
        return AgentTabKey(machine: machine, key: key)
    }

    public mutating func removeValue(forKey key: AgentTabKey) -> Value? {
        guard let value = storage.removeValue(forKey: key) else { return nil }
        machines[key.key]?.remove(key.machine)
        if machines[key.key]?.isEmpty == true { machines[key.key] = nil }
        return value
    }

    public func filter(_ isIncluded: ((key: AgentTabKey, value: Value)) throws -> Bool) rethrows -> AgentTabMap<Value> {
        var result = AgentTabMap<Value>()
        for (key, value) in storage where try isIncluded((key: key, value: value)) { result[key] = value }
        return result
    }
}

private extension Collection where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
