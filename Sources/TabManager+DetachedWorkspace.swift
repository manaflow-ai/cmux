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
            let insertIndex = detachedWorkspaceInsertIndex(
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
            if insertIndex >= 0 && insertIndex <= updatedTabs.count {
                updatedTabs.insert(newWorkspace, at: insertIndex)
            } else {
                updatedTabs.append(newWorkspace)
            }
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
        let clampedInsertion = max(0, min(proposedInsertion, tabs.count))
        let pinnedCount = tabs.reduce(into: 0) { count, tab in
            if tab.isPinned {
                count += 1
            }
        }
        return max(clampedInsertion, pinnedCount)
    }
}
