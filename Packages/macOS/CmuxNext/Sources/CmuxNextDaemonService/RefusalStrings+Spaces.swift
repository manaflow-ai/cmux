public import CmuxNextDaemon
import Foundation

/// Why Delete Space… can't delete a space. The daemon never deletes the Default space, so it is
/// also the last space there is: the space menu shows the row dimmed with the reason, and the
/// palette, CLI and MCP are refused with it before any question (Leo, 2026-11-02: what happens
/// "if you delete your one and only space").
nonisolated extension RefusalStrings {
    /// Delete Space… on the only space.
    public static var onlySpaceCannotBeDeleted: String { text("handlers.refusal.space.onlySpace", "This is your only space.") }
    /// Delete Space… on the Default space while others exist.
    public static var defaultSpaceCannotBeDeleted: String { text("handlers.refusal.space.defaultKept", "The Default space can't be deleted.") }

    /// The reason Delete Space… refuses `room` of `store`, nil for a space it deletes.
    @MainActor
    public static func spaceDelete(_ room: ProfileID, in store: DaemonStore) -> String? {
        guard room == .defaultProfile else { return nil }
        return store.profileIDs.count <= 1 ? onlySpaceCannotBeDeleted : defaultSpaceCannotBeDeleted
    }
}
