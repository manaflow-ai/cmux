import CmuxSettings
import Foundation

/// Persists auto-assigned workspace rail colors, keyed by `Workspace.stableId`.
///
/// Assignments are remembered rather than recomputed so a workspace keeps its
/// color when other workspaces are created, reordered, or deleted. Recomputing
/// from the current workspace list would shift colors around whenever the list
/// changed, which is exactly the flicker this feature is meant to avoid.
///
/// Storage is a dedicated `UserDefaults` key owned by this feature. Auto colors
/// deliberately do not go through `WorkspaceCustomization` or the session
/// snapshot: those record *user* intent, and an auto color is not something the
/// user chose. Keeping them separate also means disabling the feature leaves no
/// residue in workspace state.
enum WorkspaceAutoColorAssignmentStore {
    /// `[stableId.uuidString: paletteHex]`.
    static let defaultsKey = "workspaceTabColor.autoAssignments"

    /// Stale entries are only collected once the map is far larger than any
    /// real workspace count, so ordinary use never risks a destructive prune.
    static let pruneThreshold = 512

    static func assignments(defaults: UserDefaults = .standard) -> [String: String] {
        defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func assignedColorHex(
        for stableId: UUID,
        defaults: UserDefaults = .standard
    ) -> String? {
        assignments(defaults: defaults)[stableId.uuidString]
    }

    /// Brings stored assignments in line with the current workspaces.
    ///
    /// Gives every workspace in `needingAssignment` a color if it does not have
    /// one yet. Existing assignments are never rewritten, which is what keeps
    /// colors stable across creation, reorder, and deletion.
    ///
    /// `liveIds` decides which stored colors count as *in use* for allocation,
    /// but does not by itself delete anything. A caller can only see the
    /// workspaces of the windows it knows about, and a list that is partial —
    /// mid-restore, or one window out of several — would otherwise delete the
    /// rest and reshuffle every color on the next pass. Stale entries are
    /// garbage-collected only once the map grows past `pruneThreshold`, which
    /// normal use never reaches.
    ///
    /// - Parameters:
    ///   - needingAssignment: Stable ids of workspaces eligible for an auto
    ///     color, in allocation order (normally sidebar order). Workspaces with
    ///     a manual color must be excluded.
    ///   - liveIds: Stable ids of every workspace the caller can see. Includes
    ///     manually colored workspaces, so their color is held for them and
    ///     comes back if the manual color is cleared.
    ///   - manualColorHexes: Colors the user chose explicitly, so a newly
    ///     allocated auto color avoids duplicating them.
    /// - Returns: The reconciled assignment map.
    @discardableResult
    static func reconcile(
        needingAssignment: [UUID],
        liveIds: Set<UUID>,
        manualColorHexes: [String],
        palette: [WorkspaceTabColorEntry],
        defaults: UserDefaults = .standard
    ) -> [String: String] {
        var stored = assignments(defaults: defaults)
        let before = stored
        let liveKeys = Set(liveIds.map(\.uuidString))

        let paletteKeys = Set(palette.map { WorkspaceAutoTabColorAssignment.normalized($0.hex) })
        // Drop assignments whose color left the palette so the workspace can be
        // reallocated a color that still exists.
        stored = stored.filter {
            paletteKeys.contains(WorkspaceAutoTabColorAssignment.normalized($0.value))
        }

        if stored.count > pruneThreshold {
            stored = stored.filter { liveKeys.contains($0.key) }
        }

        for id in needingAssignment where stored[id.uuidString] == nil {
            // Only colors on screen count as used. A dead workspace's color must
            // not keep a palette slot reserved forever.
            let used = stored.filter { liveKeys.contains($0.key) }.values + manualColorHexes
            guard let hex = WorkspaceAutoTabColorAssignment.nextColorHex(
                palette: palette,
                usedHexes: Array(used)
            ) else {
                break
            }
            stored[id.uuidString] = hex
        }

        if stored != before {
            if stored.isEmpty {
                defaults.removeObject(forKey: defaultsKey)
            } else {
                defaults.set(stored, forKey: defaultsKey)
            }
        }
        return stored
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
