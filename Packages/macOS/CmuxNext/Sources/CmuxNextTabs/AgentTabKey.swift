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
    /// Which values the map lists in ``marked`` (nil: none). Asked when a value is written, never later.
    private let marks: ((Value) -> Bool)?
    /// The keys whose value `marks` took when it was written: a caller that looks for the few values of one kind
    /// (the New Tab pages among every chat's page view) reads these, never every key. The map's two writes (its
    /// subscript and ``removeValue(forKey:)``) are the only places that keep it, so no caller can leave it stale;
    /// a value that changed its kind after its write leaves at the next ``firstMarked(first:take:where:)``.
    public private(set) var marked: Set<AgentTabKey> = []

    public typealias Element = (key: AgentTabKey, value: Value)
    public typealias Iterator = IndexingIterator<[Element]>

    public init(marking marks: ((Value) -> Bool)? = nil) { self.marks = marks }

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
                if let marks { if marks(newValue) { marked.insert(key) } else { marked.remove(key) } }
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
        marked.remove(key)
        return value
    }

    /// A marked value that `wanted` takes, with its key; nil when there is none. `take` removes it from the map.
    /// A marked key whose value `marks` no longer takes (a New Tab page that became a chat) leaves the marks here,
    /// so they stay few: that is the one change a call with no `take` makes. `first`: the tab id whose marked keys
    /// the walk tries before each other key. The marks are a set, and the walk of a set has an order that changes
    /// from run to run: a caller that has one value which it wants before the others (the page view of the tab that
    /// a pane leaves, before a page view of another pane) names it here.
    public mutating func firstMarked(first: String? = nil, take: Bool = false, where wanted: (AgentTabKey, Value) -> Bool) -> Element? {
        for key in marked.filter({ $0.key == first }).map({ $0 }) + marked.filter({ $0.key != first }) {
            guard let value = storage[key], marks?(value) == true else {
                marked.remove(key)
                continue
            }
            guard wanted(key, value) else { continue }
            if take { _ = removeValue(forKey: key) }
            return (key: key, value: value)
        }
        return nil
    }

    public func filter(_ isIncluded: ((key: AgentTabKey, value: Value)) throws -> Bool) rethrows -> AgentTabMap<Value> {
        var result = AgentTabMap<Value>(marking: marks)
        for (key, value) in storage where try isIncluded((key: key, value: value)) { result[key] = value }
        return result
    }
}

/// A map of aliases: each key is a tab id that names the tab id in its value (a provisional id and the store's id).
extension AgentTabMap where Value == String {
    /// Whether `holds` takes tab id `id` or an id here that names it. A caller that asks by a tab's stored id (is a
    /// pane drawing it?) also asks by the provisional id that the pane may still use.
    public func names(_ id: String, where holds: (String) -> Bool) -> Bool {
        holds(id) || storage.contains { $0.value == id && holds($0.key.key) }
    }

    /// Removes each alias of `machine`, or of no machine, that names tab id `id` or that is `id`'s own.
    public mutating func removeAliases(of id: String, machine: String) {
        for (key, value) in storage where (key.machine == machine || key.machine.isEmpty) && (value == id || key.key == id) {
            _ = removeValue(forKey: key)
        }
    }
}

private extension Collection where Element: Hashable {
    func unique() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
