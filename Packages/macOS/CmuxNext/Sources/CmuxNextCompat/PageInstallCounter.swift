public import Observation

/// Bumped whenever a page is installed, so tab strips that show a live page
/// instead of its daemon record (incognito tabs) re-render once it exists.
/// `generation(of:)` moves when tab `key`'s page is installed or closed and
/// observes that tab only (a sidebar row: TYPING UNDER LOAD F6).
@MainActor @Observable
public final class PageInstallCounter {
    public private(set) var revision = 0
    @ObservationIgnored private let generations = ObservedMap<String, UInt64>()

    public init() {}

    /// Tabs `keys` got a page (`installed`, which also moves `revision`) or lost one.
    public func bump(_ keys: some Sequence<String>, installed: Bool = true) {
        if installed { revision &+= 1 }
        for key in keys { generations[key] = generation(of: key) &+ 1 }
    }

    /// Moves when tab `key`'s page is installed or closed; observes `key` only.
    public func generation(of key: String) -> UInt64 { generations[key] ?? 0 }

    /// Forgets a tab that is gone for good. The slot is cleared first so a
    /// reader of the tab's generation re-runs once, then the empty slot is
    /// dropped so a long session does not retain every closed tab id.
    public func forget(_ key: String) {
        generations.removeSlot(forKey: key)
    }
}
