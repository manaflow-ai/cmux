import CmuxNextCompat

/// The tabs showing the New Tab page, for observers (the tab strip), keyed
/// (`ObservedMap`): `contains(key)` observes tab `key` only, so opening or
/// closing one New Tab page re-maps only the strip that shows it.
@MainActor
public final class NewTabPageIDs {
    private let pages = ObservedMap<String, Bool>()

    public init() {}

    /// Makes `ids` the page tabs; writes only the keys that change. The machine-qualified form
    /// keeps two daemons' reused tab ids independent while the legacy overload remains for callers
    /// that truly have no machine identity.
    public func set(_ ids: Set<String>) {
        for key in pages.keys where !ids.contains(key) { pages[key] = nil }
        for key in ids { pages[key] = true }
    }

    public func set(_ ids: [(machine: String, key: String)]) {
        let encoded = Set(ids.map { Self.encode(machine: $0.machine, key: $0.key) })
        for key in pages.keys where !encoded.contains(key) { pages[key] = nil }
        for key in encoded { pages[key] = true }
    }

    public func contains(_ key: String) -> Bool { pages[key] == true }

    public func contains(_ key: String, machine: String?) -> Bool {
        guard let machine else { return contains(key) }
        return pages[Self.encode(machine: machine, key: key)] == true
    }

    /// Every page tab (observes the set, not each key).
    public var ids: Set<String> { Set(pages.keys.map(Self.key)) }

    private static func encode(machine: String, key: String) -> String { "\u{1f}\(machine)\u{1f}\(key)" }
    private static func key(_ encoded: String) -> String {
        guard encoded.first == "\u{1f}", let split = encoded.dropFirst().firstIndex(of: "\u{1f}") else { return encoded }
        return String(encoded[encoded.index(after: split)...])
    }
}
