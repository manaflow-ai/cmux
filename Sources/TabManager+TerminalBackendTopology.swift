import Bonsplit
import CmuxTerminal
import CmuxTerminalBackend
import Foundation

/// Projects daemon-owned terminal structure while carrying client-owned panels
/// across every resnapshot as an explicit Swift-only overlay.
@MainActor
extension TabManager: TerminalBackendTopologyProjecting {
    private struct ClientOverlaySource {
        let workspaceID: UUID
        let title: String
        let customTitle: String?
        let groupID: UUID?
        let orderedPanelIDs: [UUID]
    }

    func legacyTerminalPlacements() -> Set<TerminalBackendTopologyPlacement> {
        Set(tabs.flatMap { workspace in
            workspace.panels.values.compactMap { panel in
                guard panel is TerminalPanel else { return nil }
                return TerminalBackendTopologyPlacement(
                    workspaceID: workspace.id,
                    surfaceID: panel.id
                )
            }
        })
    }

    func installCanonicalTopology(_ snapshot: TopologySnapshot) throws {
        let plan = try TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        let previousTabs = tabs
        let previousSelection = selectedTabId
        let previousGroups = workspaceGroups
        let oldGroupIDs = Dictionary(
            uniqueKeysWithValues: previousTabs.map { ($0.id, $0.groupId) }
        )

        // Build and validate the entire canonical terminal tree before touching
        // the live Swift workspace array or detaching any client-owned panel.
        var canonicalWorkspaces: [Workspace] = []
        for workspacePlan in plan.workspaces {
            let workspace = try makeCanonicalWorkspace(workspacePlan)
            workspace.groupId = oldGroupIDs[workspace.id] ?? nil
            canonicalWorkspaces.append(workspace)
        }

        let overlaySources = previousTabs.compactMap { workspace -> ClientOverlaySource? in
            let orderedPanelIDs = workspace.sidebarOrderedPanelIds().filter {
                guard let panel = workspace.panels[$0] else { return false }
                return !(panel is TerminalPanel)
            }
            guard !orderedPanelIDs.isEmpty else { return nil }
            return ClientOverlaySource(
                workspaceID: workspace.id,
                title: workspace.title,
                customTitle: workspace.customTitle,
                groupID: workspace.groupId,
                orderedPanelIDs: orderedPanelIDs
            )
        }

        let canonicalByID = Dictionary(
            uniqueKeysWithValues: canonicalWorkspaces.map { ($0.id, $0) }
        )
        var clientOnlyWorkspaces: [Workspace] = []

        for source in overlaySources {
            guard let oldWorkspace = previousTabs.first(where: { $0.id == source.workspaceID }) else {
                throw TerminalBackendTopologyProjectionError.projectionFailed("overlay source disappeared")
            }
            var transfers: [Workspace.DetachedSurfaceTransfer] = []
            for panelID in source.orderedPanelIDs {
                guard let transfer = oldWorkspace.detachSurface(panelId: panelID) else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed("client overlay detach")
                }
                transfers.append(transfer)
            }
            guard let firstTransfer = transfers.first else { continue }

            if let canonicalWorkspace = canonicalByID[source.workspaceID] {
                guard let targetPane = canonicalWorkspace.bonsplitController.allPaneIds.first else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed("canonical overlay pane")
                }
                for transfer in transfers {
                    guard canonicalWorkspace.attachDetachedSurface(
                        transfer,
                        inPane: targetPane,
                        focus: false
                    ) != nil else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed("canonical overlay attach")
                    }
                }
            } else {
                let overlayWorkspace = Workspace(
                    id: source.workspaceID,
                    title: source.title,
                    initialDetachedSurface: firstTransfer,
                    terminalClientComposition: terminalClientComposition
                )
                overlayWorkspace.groupId = source.groupID
                if let customTitle = source.customTitle {
                    overlayWorkspace.setCustomTitle(customTitle)
                }
                guard let targetPane = overlayWorkspace.bonsplitController.allPaneIds.first else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed("client overlay pane")
                }
                for transfer in transfers.dropFirst() {
                    guard overlayWorkspace.attachDetachedSurface(
                        transfer,
                        inPane: targetPane,
                        focus: false
                    ) != nil else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed("client overlay attach")
                    }
                }
                clientOnlyWorkspaces.append(overlayWorkspace)
            }
        }

        let projectedTabs = canonicalWorkspaces + clientOnlyWorkspaces
        guard !projectedTabs.isEmpty else {
            throw TerminalBackendTopologyProjectionError.projectionFailed("empty Swift shell")
        }

        for workspace in previousTabs {
            unwireClosedBrowserTracking(for: workspace)
            workspace.owningTabManager = nil
        }
        for workspace in projectedTabs {
            workspace.owningTabManager = self
            wireClosedBrowserTracking(for: workspace)
        }

        tabs = projectedTabs
        let liveWorkspaceIDs = Set(projectedTabs.map(\.id))
        workspaceGroups = previousGroups.filter { liveWorkspaceIDs.contains($0.anchorWorkspaceId) }
        if let previousSelection, liveWorkspaceIDs.contains(previousSelection) {
            selectedTabId = previousSelection
        } else {
            selectedTabId = projectedTabs.first?.id
        }
    }

    private func makeCanonicalWorkspace(
        _ plan: TerminalBackendTopologyProjectionPlan.Workspace
    ) throws -> Workspace {
        let panesByID = Dictionary(
            uniqueKeysWithValues: plan.screen.panes.map { ($0.uuid.rawValue, $0) }
        )
        let firstPane = try canonicalFirstPane(in: plan.screen.layout, panesByID: panesByID)
        guard let firstSurface = firstPane.tabs.first else {
            throw TerminalBackendTopologyProjectionError.missingPane(firstPane.uuid.rawValue)
        }
        let workspace = Workspace(
            id: plan.canonical.uuid.rawValue,
            title: plan.canonical.name,
            terminalClientComposition: terminalClientComposition,
            initialTerminalSurfaceID: firstSurface.uuid.rawValue,
            initialTerminalPaneID: firstPane.uuid.rawValue
        )
        workspace.isApplyingCanonicalTopologyProjection = true
        defer { workspace.isApplyingCanonicalTopologyProjection = false }

        try installCanonicalLayout(
            plan.screen.layout,
            in: workspace,
            panesByID: panesByID,
            anchorSurfaceID: firstSurface.uuid.rawValue
        )
        workspace.applyProcessTitle(plan.canonical.name)
        return workspace
    }

    private func installCanonicalLayout(
        _ layout: CanonicalLayout,
        in workspace: Workspace,
        panesByID: [UUID: CanonicalPane],
        anchorSurfaceID: UUID
    ) throws {
        switch layout {
        case .leaf(_, let paneUUID):
            guard let pane = panesByID[paneUUID.rawValue],
                  pane.tabs.first?.uuid.rawValue == anchorSurfaceID,
                  let localPaneID = workspace.paneId(forPanelId: anchorSurfaceID),
                  localPaneID.id == paneUUID.rawValue else {
                throw TerminalBackendTopologyProjectionError.missingPane(paneUUID.rawValue)
            }
            applyCanonicalSurfaceName(pane.tabs[0], in: workspace)
            for surface in pane.tabs.dropFirst() {
                guard workspace.newTerminalSurface(
                    inPane: localPaneID,
                    focus: false,
                    autoRefreshMetadata: false,
                    preserveFocusWhenUnfocused: true,
                    restoredSurfaceId: surface.uuid.rawValue,
                    creationOrigin: .sessionRestore
                ) != nil else {
                    throw TerminalBackendTopologyProjectionError.missingSurface(surface.uuid.rawValue)
                }
                applyCanonicalSurfaceName(surface, in: workspace)
            }

        case .split(let direction, let ratio, let first, let second):
            let secondPane = try canonicalFirstPane(in: second, panesByID: panesByID)
            guard let secondSurface = secondPane.tabs.first else {
                throw TerminalBackendTopologyProjectionError.missingPane(secondPane.uuid.rawValue)
            }
            let orientation: SplitOrientation = direction == .right ? .horizontal : .vertical
            guard workspace.newTerminalSplit(
                from: anchorSurfaceID,
                orientation: orientation,
                focus: false,
                initialDividerPosition: CGFloat(ratio),
                restoredSurfaceId: secondSurface.uuid.rawValue,
                restoredPaneId: secondPane.uuid.rawValue
            ) != nil else {
                throw TerminalBackendTopologyProjectionError.missingSurface(secondSurface.uuid.rawValue)
            }
            try installCanonicalLayout(
                first,
                in: workspace,
                panesByID: panesByID,
                anchorSurfaceID: anchorSurfaceID
            )
            try installCanonicalLayout(
                second,
                in: workspace,
                panesByID: panesByID,
                anchorSurfaceID: secondSurface.uuid.rawValue
            )
        }
    }

    private func canonicalFirstPane(
        in layout: CanonicalLayout,
        panesByID: [UUID: CanonicalPane]
    ) throws -> CanonicalPane {
        switch layout {
        case .leaf(_, let paneUUID):
            guard let pane = panesByID[paneUUID.rawValue] else {
                throw TerminalBackendTopologyProjectionError.missingPane(paneUUID.rawValue)
            }
            return pane
        case .split(_, _, let first, _):
            return try canonicalFirstPane(in: first, panesByID: panesByID)
        }
    }

    private func applyCanonicalSurfaceName(
        _ surface: CanonicalSurface,
        in workspace: Workspace
    ) {
        guard let name = surface.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return }
        _ = workspace.updatePanelTitle(panelId: surface.uuid.rawValue, title: name)
    }
}
