import CmuxNextSidebar
import Foundation

/// The one-time, lossless move of legacy pinned workspaces
/// (`workspace-pin-v1`, a per-session flag) into workspace tiles
/// (PINNED-ITEMS-END-TO-END step 3 item 6). Per session whose tree has
/// loaded: each pinned workspace the top region does not show yet becomes
/// a tile, through ordinary intents (one op per workspace; the store's L3
/// dedupe makes a repeat a no-op). The session is marked done on this Mac
/// only once the owner's confirmed layout shows every one of them. The ops
/// go out once per session per launch (a refused op waits for the next
/// launch instead of looping against a permanent reject). The legacy flag
/// is never cleared here and stays readable; after the mark, this Mac
/// ignores it.
extension SidebarLayoutService {
    static let legacyPinsMigratedKey = "cmux.next.sidebar.legacyPinsMigrated"

    /// Sessions this Mac has moved.
    var legacyPinsMigrated: Set<String> { Set(recentsOffered.stringArray(forKey: Self.legacyPinsMigratedKey) ?? []) }

    func migrateLegacyPins() {
        guard let remote, usesOwner else { return }
        var migrated = legacyPinsMigrated
        let before = migrated
        for group in remote.legacyPins where !migrated.contains(group.session) {
            if group.refs.allSatisfy(mirror.isOnTop) {
                migrated.insert(group.session)
                continue
            }
            // Once per run: the next fetch after the owner's replies marks it done.
            guard !legacyPinsSent.contains(group.session) else { continue }
            legacyPinsSent.insert(group.session)
            for op in document.legacyPinMigrationOps(group.refs) {
                do { try send(op) } catch { break }
            }
        }
        if migrated != before { recentsOffered.set(migrated.sorted(), forKey: Self.legacyPinsMigratedKey) }
    }
}
