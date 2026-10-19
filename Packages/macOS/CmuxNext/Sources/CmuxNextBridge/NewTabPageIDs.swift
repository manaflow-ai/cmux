import CmuxNextCompat

/// The tabs showing the New Tab page, for observers (the tab strip), keyed
/// (`ObservedMap`): `contains(key)` observes tab `key` only, so opening or
/// closing one New Tab page re-maps only the strip that shows it.
@MainActor
public final class NewTabPageIDs {
    private let pages = ObservedMap<String, Bool>()

    public init() {}

    /// Makes `ids` the page tabs; writes only the keys that change.
    public func set(_ ids: Set<String>) {
        for key in pages.keys where !ids.contains(key) { pages[key] = nil }
        for key in ids { pages[key] = true }
    }

    public func contains(_ key: String) -> Bool { pages[key] == true }

    /// Every page tab (observes the set, not each key).
    public var ids: Set<String> { Set(pages.keys) }
}
