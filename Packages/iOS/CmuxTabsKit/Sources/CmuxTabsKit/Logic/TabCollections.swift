import Foundation

/// Safari's pinned tabs: pinned items sit in the pinned area above the grid
/// (capsules, in pin order); the rest keep their grid order. Kept per host.
struct TabPins: Equatable, Sendable {
    /// Pinned item keys, in the order they were pinned.
    private(set) var keys: [String] = []

    init(keys: [String] = []) { self.keys = keys }

    func isPinned(_ key: String) -> Bool { keys.contains(key) }

    mutating func pin(_ key: String) { if !keys.contains(key) { keys.append(key) } }
    mutating func unpin(_ key: String) { keys.removeAll { $0 == key } }

    /// `order` with the pinned items first (in pin order); pins for items
    /// that no longer exist are ignored.
    func arranged(_ order: [String]) -> [String] {
        let present = Set(order)
        let pinned = keys.filter { present.contains($0) }
        let pinnedSet = Set(pinned)
        return pinned + order.filter { !pinnedSet.contains($0) }
    }

    /// How many of `order`'s items are pinned.
    func count(in order: [String]) -> Int {
        let present = Set(order)
        return keys.filter { present.contains($0) }.count
    }

    /// Drops pins of items that are gone (closed).
    mutating func retain(_ existing: Set<String>) { keys.removeAll { !existing.contains($0) } }

    // MARK: Persistence (per host, on this device)

    static func defaultsKey(host: String) -> String { "cn.tabs.pinned.\(host)" }

    static func load(host: String, from defaults: UserDefaults = .standard) -> TabPins {
        TabPins(keys: defaults.stringArray(forKey: defaultsKey(host: host)) ?? [])
    }

    func save(host: String, to defaults: UserDefaults = .standard) {
        defaults.set(keys, forKey: Self.defaultsKey(host: host))
    }
}

/// Safari's Select Tabs mode: cards toggle with a checkmark; the bar offers
/// Close (all selected), Pin and Copy Links.
struct TabSelection: Equatable, Sendable {
    private(set) var selected: [String] = []

    var count: Int { selected.count }
    var isEmpty: Bool { selected.isEmpty }
    func contains(_ key: String) -> Bool { selected.contains(key) }

    mutating func toggle(_ key: String) {
        if let i = selected.firstIndex(of: key) { selected.remove(at: i) } else { selected.append(key) }
    }

    /// Keeps only items that still exist, in grid order.
    mutating func retain(_ order: [String]) {
        let s = Set(selected)
        selected = order.filter { s.contains($0) }
    }

    /// The keys a bulk action applies to, in grid order.
    func keys(in order: [String]) -> [String] {
        let s = Set(selected)
        return order.filter { s.contains($0) }
    }

    /// "2 selected" (the pill), "Close 2 Tabs" (the confirmation), and the
    /// More menu's "Pin 2 Tabs" / "Copy 2 Links".
    var title: String { "\(count) selected" }
    var closeTitle: String { count == 1 ? "Close 1 Tab" : "Close \(count) Tabs" }
    var pinTitle: String { count == 1 ? "Pin 1 Tab" : "Pin \(count) Tabs" }
    var copyTitle: String { count == 1 ? "Copy 1 Link" : "Copy \(count) Links" }
}
