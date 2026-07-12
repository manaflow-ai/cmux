import Foundation

enum WorkspaceSurfaceResumeTargetLookup {
    case found(UUID)
    case missing
    case ambiguous
}

extension Workspace {
    /// Re-adopts a persisted panel identity unless it is still live elsewhere.
    func adoptPersistedStableSurfaceId(from snapshot: SessionPanelSnapshot, panelId: UUID) {
        if let stableSurfaceId = snapshot.stableSurfaceId,
           sessionRestoreIdentityExclusions.shouldAdopt(stableSurfaceId),
           let panel = panels[panelId] {
            panel.adoptStableSurfaceId(stableSurfaceId)
        }
    }

    func restoreClosedPanel(
        _ entry: ClosedPanelHistoryEntry,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }
        return restoreClosedPanel(entry)
    }

    /// Resolves a resume target only when its runtime or restart-stable id is unique.
    func surfaceResumeTargetLookup(_ targetId: UUID) -> WorkspaceSurfaceResumeTargetLookup {
        var matches = Set<UUID>()
        if terminalPanel(for: targetId) != nil {
            matches.insert(targetId)
        }
        for panel in panels.values {
            guard panel.stableSurfaceId == targetId,
                  terminalPanel(for: panel.id) != nil else {
                continue
            }
            matches.insert(panel.id)
        }
        guard let match = matches.first else { return .missing }
        guard matches.count == 1 else { return .ambiguous }
        return .found(match)
    }
}
