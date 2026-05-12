import Foundation

extension TabManager {
    struct WorkspaceCreationTabSnapshot {
        let id: UUID
        let isPinned: Bool

        @MainActor
        init(workspace: Workspace) {
            self.id = workspace.id
            self.isPinned = workspace.isPinned
        }
    }

    struct WorkspaceCreationSnapshot {
        let tabs: [WorkspaceCreationTabSnapshot]
        let selectedTabId: UUID?
        let selectedTabWasPinned: Bool
        let preferredWorkingDirectory: String?
        let inheritedTerminalFontPoints: Float?
    }

    @discardableResult
    func addWorkspace(
        fromDetachedSurface detached: Workspace.DetachedSurfaceTransfer,
        title: String? = nil,
        select: Bool = true,
        placementOverride: NewWorkspacePlacement? = nil,
        insertionIndexOverride: Int? = nil,
        focusIntent: PanelFocusIntent? = nil
    ) -> Workspace? {
        let sourceWorkspace = selectedWorkspace
        let capturedTabs = tabs
        let capturedSelectedTabId = sourceWorkspace?.id

        return withExtendedLifetime((capturedTabs, sourceWorkspace, detached.panel)) {
            let inheritedDirectory = preferredWorkingDirectoryForNewTab(workspace: sourceWorkspace)
            let font = inheritedTerminalFontPointsForNewWorkspace(workspace: sourceWorkspace)
            let snapshot = workspaceCreationSnapshotLite(
                currentTabs: capturedTabs,
                currentSelectedTabId: capturedSelectedTabId,
                preferredWorkingDirectory: inheritedDirectory,
                inheritedTerminalFontPoints: font
            )
            didCaptureWorkspaceCreationSnapshot()
#if DEBUG
            maybeMutateSelectionDuringWorkspaceCreationForDev(snapshot: snapshot)
#endif
            let nextTabCount = snapshot.tabs.count + 1
            sentryBreadcrumb("workspace.create.fromDetachedSurface", data: ["tabCount": nextTabCount])

            let inheritedConfig = workspaceCreationConfigTemplate(
                inheritedTerminalFontPoints: snapshot.inheritedTerminalFontPoints
            )
            let plannedInsertIndex = detachedWorkspaceInsertIndex(
                insertionIndexOverride: insertionIndexOverride,
                snapshot: snapshot,
                placementOverride: placementOverride
            )
            let ordinal = Self.nextPortOrdinal
            Self.nextPortOrdinal += 1
            let newWorkspace = Workspace(
                title: title ?? detached.title,
                workingDirectory: normalizedWorkingDirectory(detached.directory) ?? snapshot.preferredWorkingDirectory,
                portOrdinal: ordinal,
                configTemplate: inheritedConfig,
                initialDetachedSurface: detached
            )
            guard newWorkspace.panels[detached.panelId] != nil else { return nil }

            applyCreationChromeInheritance(to: newWorkspace, from: sourceWorkspace ?? capturedTabs.first)
            newWorkspace.owningTabManager = self
            if title != nil {
                newWorkspace.setCustomTitle(title)
            }
            wireClosedBrowserTracking(for: newWorkspace)

            var updatedTabs = tabs
            let insertIndex = Self.clampedDetachedWorkspaceInsertIndex(plannedInsertIndex, workspaces: updatedTabs)
            updatedTabs.insert(newWorkspace, at: insertIndex)
            tabs = updatedTabs

            if select {
#if DEBUG
                debugPrimeWorkspaceSwitchTrigger("createFromDetachedSurface", to: newWorkspace.id)
#endif
                selectedTabId = newWorkspace.id
                NotificationCenter.default.post(
                    name: .ghosttyDidFocusTab,
                    object: nil,
                    userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
                )
                newWorkspace.focusPanel(detached.panelId, focusIntent: focusIntent)
            }
#if DEBUG
            UITestRecorder.incrementInt("addTabInvocations")
            UITestRecorder.record([
                "tabCount": String(updatedTabs.count),
                "selectedTabId": select ? newWorkspace.id.uuidString : (snapshot.selectedTabId?.uuidString ?? "")
            ])
#endif
            return newWorkspace
        }
    }

    private func detachedWorkspaceInsertIndex(
        insertionIndexOverride: Int?,
        snapshot: WorkspaceCreationSnapshot,
        placementOverride: NewWorkspacePlacement?
    ) -> Int {
        guard let insertionIndexOverride else {
            return newTabInsertIndex(snapshot: snapshot, placementOverride: placementOverride)
        }
        return Self.clampedDetachedWorkspaceInsertIndex(insertionIndexOverride, tabs: snapshot.tabs)
    }

    private static func clampedDetachedWorkspaceInsertIndex(
        _ proposedInsertion: Int,
        tabs: [WorkspaceCreationTabSnapshot]
    ) -> Int {
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if tab.isPinned {
                count += 1
            }
        }
        return clampedDetachedWorkspaceInsertIndex(proposedInsertion, totalCount: tabs.count, pinnedCount: pinnedCount)
    }

    private static func clampedDetachedWorkspaceInsertIndex(
        _ proposedInsertion: Int,
        workspaces: [Workspace]
    ) -> Int {
        let pinnedCount = workspaces.prefix { $0.isPinned }.count
        return clampedDetachedWorkspaceInsertIndex(
            proposedInsertion,
            totalCount: workspaces.count,
            pinnedCount: pinnedCount
        )
    }

    private static func clampedDetachedWorkspaceInsertIndex(
        _ proposedInsertion: Int,
        totalCount: Int,
        pinnedCount: Int
    ) -> Int {
        let clampedCount = max(0, totalCount)
        let clampedPinnedCount = max(0, min(pinnedCount, clampedCount))
        let clampedInsertion = max(0, min(proposedInsertion, clampedCount))
        return max(clampedInsertion, clampedPinnedCount)
    }
}
