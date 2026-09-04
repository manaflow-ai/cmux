import Bonsplit
import CmuxBrowser
import CmuxArtifacts
import CmuxWorkspaces
import Foundation

extension Workspace {
    /// Creates the workspace-owned Artifacts surface (legacy Links wire kind).
    @discardableResult
    func newWorkspaceArtifactsSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> ArtifactsPanel? {
        newWorkspaceLinksSurface(inPane: paneId, focus: focus, targetIndex: targetIndex)
    }

    /// Opens or focuses the workspace-owned Artifacts surface.
    @discardableResult
    func openOrFocusWorkspaceArtifactsSurface(inPane paneId: PaneID, focus: Bool = true) -> ArtifactsPanel? {
        openOrFocusWorkspaceLinksSurface(inPane: paneId, focus: focus)
    }

    @discardableResult
    func newWorkspaceLinksSurface(
        inPane paneId: PaneID,
        focus: Bool? = nil,
        targetIndex: Int? = nil
    ) -> LinksPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)
        let previousFocusedPanelId = focusedPanelId
        let previousHostedView = focusedTerminalInputTarget()?.panel.hostedView

        let linksPanel = LinksPanel(
            workspace: self,
            titleFetcher: LinkTitleFetcher(
                pageMetadataFetcher: BrowserPageMetadataService()
            )
        )
        panels[linksPanel.id] = linksPanel
        panelTitles[linksPanel.id] = linksPanel.displayTitle

        guard let newTabId = bonsplitController.createTab(
            title: linksPanel.displayTitle,
            icon: linksPanel.displayIcon,
            kind: SurfaceKind.links.rawValue,
            isDirty: false,
            isLoading: false,
            isPinned: false,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: linksPanel.id)
            panelTitles.removeValue(forKey: linksPanel.id)
            return nil
        }

        bindSurface(newTabId, toPanelId: linksPanel.id)
        if let targetIndex {
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }
        publishCmuxSurfaceCreated(
            linksPanel.id,
            paneId: paneId,
            kind: SurfaceKind.links.rawValue,
            // Keep the lifecycle origin stable for existing consumers. The
            // user-facing title is now Artifacts, but this is still the
            // persisted Links surface during the compatibility window.
            origin: "links_tab",
            focused: shouldFocusNewTab
        )
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            preserveFocusAfterNonFocusSplit(
                preferredPanelId: previousFocusedPanelId,
                splitPanelId: linksPanel.id,
                previousHostedView: previousHostedView
            )
        }

        return linksPanel
    }

    @discardableResult
    func openOrFocusWorkspaceLinksSurface(
        inPane paneId: PaneID,
        focus: Bool = true
    ) -> LinksPanel? {
        guard !isRetiredFromOwningTabManager else { return nil }
        for (existingId, panel) in panels {
            guard let linksPanel = panel as? LinksPanel else { continue }
            if focus {
                focusPanel(existingId)
            }
            return linksPanel
        }
        return newWorkspaceLinksSurface(inPane: paneId, focus: focus)
    }

    func combineLinksStateIntoSessionAutosaveFingerprint(into hasher: inout Hasher) {
        hasher.combine(linksState.persistenceRevision)
    }

    func restoreLinksState(
        from snapshot: SessionWorkspaceSnapshot,
        panelIDMap: [UUID: UUID]
    ) {
        let restoredEntries = snapshot
            .restoredLinks
            .map { entry in
                var entry = entry
                entry.sourcePanelId = entry.sourcePanelId.flatMap { panelIDMap[$0] }
                return entry
            }
        linksState.restore(
            restoredEntries,
            retentionLimit: linksState.retentionLimit
        )
    }

    /// Restores the unified artifact projection after legacy Links migration.
    func restoreArtifactsState(
        from snapshot: SessionWorkspaceSnapshot,
        panelIDMap: [UUID: UUID] = [:]
    ) {
        guard !snapshot.restoredArtifacts.isEmpty else { return }
        let restored = snapshot.restoredArtifacts.map { record -> ArtifactRecord in
            guard let oldPanelID = record.metadata["sourcePanelID"].flatMap(UUID.init(uuidString:)),
                  let newPanelID = panelIDMap[oldPanelID] else {
                return record
            }
            var metadata = record.metadata
            metadata["sourcePanelID"] = newPanelID.uuidString
            return ArtifactRecord(
                id: record.id,
                kind: record.kind,
                identityKey: record.identityKey,
                ownership: record.ownership,
                source: record.source,
                createdAt: record.createdAt,
                lastSeenAt: record.lastSeenAt,
                occurrenceCount: record.occurrenceCount,
                title: record.title,
                metadata: metadata,
                representation: record.representation,
                isUserOwned: record.isUserOwned
            )
        }
        linksState.restoreArtifacts(restored, retentionLimit: linksState.retentionLimit)
    }
}
