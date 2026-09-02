import Foundation
import CmuxNestedTopology

extension Workspace {
    /// Re-adopts a persisted panel identity unless it is still live elsewhere.
    func adoptPersistedStableSurfaceId(from snapshot: SessionPanelSnapshot, panelId: UUID) {
        if let stableSurfaceId = snapshot.stableSurfaceId,
           sessionRestoreIdentityExclusions.shouldAdopt(stableSurfaceId),
           let panel = panels[panelId] {
            panel.adoptStableSurfaceId(stableSurfaceId)
        }
    }

    /// Defers nested-provider reattachment until the terminal panel and stable
    /// surface identity exist, then asks ``NestedTopologyController`` to
    /// revalidate + fetch a fresh snapshot (PR 6).
    func scheduleNestedAttachmentRestoreIfNeeded(from snapshot: SessionPanelSnapshot, panelId: UUID) {
        guard NestedTopologyController.isEnabled,
              snapshot.type == .terminal,
              let intent = snapshot.nestedAttachmentIntent,
              let panel = panels[panelId] as? TerminalPanel
        else {
            return
        }
        // Stable surface identity must already have been adopted (or freshly minted).
        let hostStableSurfaceID = panel.stableSurfaceId
        AppDelegate.shared?.nestedTopologyController.scheduleRestoreAttachment(
            hostWorkspaceID: id.uuidString,
            hostStableSurfaceID: hostStableSurfaceID,
            intent: intent
        )
    }

    func restoreClosedPanel(
        _ entry: ClosedPanelHistoryEntry,
        excludingStableIdentities: Set<UUID>
    ) -> UUID? {
        sessionRestoreIdentityExclusions.beginRestore(excluding: excludingStableIdentities)
        defer { sessionRestoreIdentityExclusions.endRestore() }
        return restoreClosedPanel(entry)
    }
}
