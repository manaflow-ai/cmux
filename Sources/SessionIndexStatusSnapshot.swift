import Foundation

/// Immutable liveness inputs shared by the main Vault table and paginated
/// popovers. Keeping the key snapshot together with its timestamp means a
/// page can derive the same status for entries that were not in the initial
/// section projection.
struct SessionIndexStatusSnapshot: Equatable, Sendable {
    let activeSessionKeys: Set<String>
    let liveSessionKeys: Set<String>
    let now: Date

    init(
        activeSessionKeys: Set<String> = [],
        liveSessionKeys: Set<String> = [],
        now: Date = .now
    ) {
        self.activeSessionKeys = activeSessionKeys
        self.liveSessionKeys = liveSessionKeys
        self.now = now
    }

    func containsActivePaneSession(_ entry: SessionEntry) -> Bool {
        activeSessionKeys.contains(VaultLiveSessionKeys.key(for: entry))
    }

    func accessory(
        for entry: SessionEntry,
        includeDetail: Bool = false
    ) -> VaultSessionRowAccessory {
        VaultSessionRowAccessory.make(
            for: entry,
            liveKeys: liveSessionKeys,
            now: now,
            includeDetail: includeDetail
        )
    }

    func presentation(
        for entry: SessionEntry,
        includeDetail: Bool = false
    ) -> (accessory: VaultSessionRowAccessory, isActive: Bool) {
        (
            accessory: accessory(for: entry, includeDetail: includeDetail),
            isActive: containsActivePaneSession(entry)
        )
    }
}
