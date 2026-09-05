import Foundation

/// Immutable row-presentation inputs shared by the main Vault table and
/// paginated popovers. Keeping the key snapshot, detail visibility, and
/// timestamp together means a page can derive the same row state for entries
/// that were not in the initial section projection.
nonisolated struct SessionIndexStatusSnapshot: Equatable, Sendable {
    let activeSessionKeys: Set<String>
    let liveSessionKeys: Set<String>
    let now: Date
    /// Whether rows rendered from this snapshot include their repository and
    /// branch subtitle. The default view keeps this enabled; compact mode
    /// supplies `false` from ``SessionIndexView``.
    let showsDetails: Bool

    init(
        activeSessionKeys: Set<String> = [],
        liveSessionKeys: Set<String> = [],
        now: Date = .now,
        showsDetails: Bool = true
    ) {
        self.activeSessionKeys = activeSessionKeys
        self.liveSessionKeys = liveSessionKeys
        self.now = now
        self.showsDetails = showsDetails
    }

    func containsActivePaneSession(_ entry: SessionEntry) -> Bool {
        activeSessionKeys.contains(VaultLiveSessionKeys.key(for: entry))
    }

    func accessory(
        for entry: SessionEntry,
        includeDetail: Bool? = nil
    ) -> VaultSessionRowAccessory {
        VaultSessionRowAccessory.make(
            for: entry,
            liveKeys: liveSessionKeys,
            now: now,
            includeDetail: includeDetail ?? showsDetails
        )
    }

    func presentation(
        for entry: SessionEntry,
        includeDetail: Bool? = nil
    ) -> (accessory: VaultSessionRowAccessory, isActive: Bool) {
        (
            accessory: accessory(for: entry, includeDetail: includeDetail),
            isActive: containsActivePaneSession(entry)
        )
    }
}
