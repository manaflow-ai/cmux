import CmuxNextSidebar
import Foundation

/// The one-time, lossless move of legacy pinned workspaces
/// (`workspace-pin-v1`, a per-session flag) into workspace tiles
/// (PINNED-ITEMS-END-TO-END step 3 item 6). Per session whose tree has
/// loaded: each pinned workspace the top region does not show yet becomes
/// a tile, through ordinary intents (one op per workspace; the store's L3
/// dedupe makes a repeat a no-op), labeled with the workspace's name. Once
/// the owner's confirmed layout shows a session's pins, their flags are
/// cleared in the session's own store: the cleared flag is the done mark,
/// so a second Mac of a shared session (a Cloud machine) does not pin
/// again a tile the user unpinned on the first. Nothing is cleared before
/// its tile is confirmed. The ops go out once per session per launch (a
/// refused op waits for the next launch instead of looping against a
/// permanent reject); so does the clear.
extension SidebarLayoutService {
    func migrateLegacyPins() {
        guard let remote, usesOwner else { return }
        for group in remote.legacyPins where !group.refs.isEmpty {
            if group.refs.allSatisfy(mirror.isOnTop) {
                guard !legacyPinsCleared.contains(group.session) else { continue }
                legacyPinsCleared.insert(group.session)
                remote.clearLegacyPins(group.refs)
                continue
            }
            // Once per run: the next fetch after the owner's replies clears the flags.
            guard !legacyPinsSent.contains(group.session) else { continue }
            legacyPinsSent.insert(group.session)
            for op in document.legacyPinMigrationOps(group.refs, labels: group.labels) {
                do { try send(op) } catch { break }
            }
        }
    }
}
