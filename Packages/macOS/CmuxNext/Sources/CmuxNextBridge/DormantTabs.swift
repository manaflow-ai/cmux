import CmuxNextCompat

/// Tabs whose page is hibernated, observable so tab strips dim them
/// (`TabItem.isDormant`) the moment they hibernate or wake. Keyed
/// (`ObservedMap`): `contains(key)` observes tab `key` only, so one tab's
/// hibernation re-maps only the strip that shows it.
@MainActor
public final class DormantTabs {
    private let flags = ObservedMap<String, Bool>()

    public init() {}

    public func set(_ key: String, _ dormant: Bool) {
        flags[key] = dormant ? true : nil
    }

    public func contains(_ key: String) -> Bool { flags[key] == true }

    /// The hibernated tabs now (diagnostics).
    public var ids: Set<String> { Set(flags.keys) }
}
