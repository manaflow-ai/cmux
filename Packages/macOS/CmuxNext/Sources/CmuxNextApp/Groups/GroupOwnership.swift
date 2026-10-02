import CmuxNextDaemon

/// Which machine's daemon owns a group: the one whose tree holds it. Group
/// commands (tab groups, screen groups) go to that daemon, never to the
/// local one by default (OWNERSHIP-PRINCIPLES: one code path picks the owner).
@MainActor
enum GroupOwnership {
    /// The daemon whose tree holds tab group `group`, nil when none does.
    static func daemon(holdingTabGroup group: TabGroupID, machines: MachineRegistry) -> DaemonService? {
        // Extracted unchanged from TabGroupMoves (always the local daemon).
        machines.local
    }
}
