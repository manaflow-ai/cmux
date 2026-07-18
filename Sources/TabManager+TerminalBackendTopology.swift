import Bonsplit
import CmuxTerminal
import CmuxTerminalBackend
import CmuxWorkspaces
import Foundation

@MainActor
private final class TabManagerTopologyProjectionState {
    struct WorkspaceSnapshot {
        let workspace: Workspace
        let panels: [UUID: any Panel]
        let title: String
        let processTitle: String
        let customTitle: String?
        let customTitleSource: Workspace.CustomTitleSource?
        let panelTitles: [UUID: String]
        let panelCustomTitles: [UUID: String]
        let panelCustomTitleSources: [UUID: Workspace.CustomTitleSource]
        let groupID: UUID?
        let tree: BonsplitAuthoritativeTree
    }

    struct Retirement {
        let workspace: Workspace
        let pane: Bonsplit.PaneID
        let index: Int
        let transfer: Workspace.DetachedSurfaceTransfer
    }

    struct TerminalPlacementAdoption {
        let panel: TerminalPanel
        let sourceWorkspace: Workspace
        let sourcePane: Bonsplit.PaneID?
        let destinationWorkspace: Workspace
        let workspaceID: UUID
    }

    struct TerminalCreation {
        let panel: TerminalPanel
        let workspace: Workspace
    }

    struct BrowserPlacementAdoption {
        let panel: BrowserPanel
        let sourceWorkspace: Workspace
        let sourcePane: Bonsplit.PaneID?
        let destinationWorkspace: Workspace
    }

    struct BrowserCreation {
        let panel: BrowserPanel
        let workspace: Workspace
    }

    struct CloudTerminalAdoption {
        let workspace: Workspace
        let pane: Bonsplit.PaneID
        let index: Int
        let loadingTransfer: Workspace.DetachedSurfaceTransfer
        let terminalPanel: TerminalPanel
    }

    struct TerminalMovementOrigin {
        let workspace: Workspace
        let pane: Bonsplit.PaneID?
    }

    let previousTabs: [Workspace]
    let previousSelection: UUID?
    let previousGroups: [WorkspaceGroup]
    let workspaceSnapshots: [UUID: WorkspaceSnapshot]
    let originalPanelOwners: [UUID: Workspace]
    var retirements: [Retirement] = []
    var terminalPlacementAdoptions: [TerminalPlacementAdoption] = []
    var terminalCreations: [TerminalCreation] = []
    var terminalMovementOrigins: [UUID: TerminalMovementOrigin] = [:]
    var browserPlacementAdoptions: [BrowserPlacementAdoption] = []
    var browserCreations: [BrowserCreation] = []
    var cloudTerminalAdoptions: [CloudTerminalAdoption] = []
    var browserMovementOrigins: [UUID: TerminalMovementOrigin] = [:]
    private(set) var touchedWorkspaces: [Workspace] = []
    private var touchedWorkspaceIdentities: Set<ObjectIdentifier> = []

    init(
        previousTabs: [Workspace],
        previousSelection: UUID?,
        previousGroups: [WorkspaceGroup],
        workspaceSnapshots: [UUID: WorkspaceSnapshot],
        originalPanelOwners: [UUID: Workspace]
    ) {
        self.previousTabs = previousTabs
        self.previousSelection = previousSelection
        self.previousGroups = previousGroups
        self.workspaceSnapshots = workspaceSnapshots
        self.originalPanelOwners = originalPanelOwners
    }

    func touch(_ workspace: Workspace) {
        guard touchedWorkspaceIdentities.insert(ObjectIdentifier(workspace)).inserted else {
            return
        }
        touchedWorkspaces.append(workspace)
    }
}

private struct TerminalBackendClientOverlayTabPlacement {
    let tabID: TabID
    let precedingCanonicalTabID: TabID?
    let followingCanonicalTabID: TabID?
    let fallbackSlot: Int
}

/// Reconciles daemon-owned terminal structure while retaining every unchanged
/// Swift presentation object and every client-owned overlay object.
@MainActor
extension TabManager: TerminalBackendTopologyProjecting {
    /// Focused-test and migration seam. Production stream delivery constructs
    /// this plan off the main actor and calls the overload below.
    func installCanonicalTopology(_ snapshot: TopologySnapshot) throws {
        try installCanonicalTopology(
            snapshot,
            plan: TerminalBackendTopologyProjectionPlan(topology: snapshot.topology)
        )
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

    func allPresentationPlacements() -> Set<TerminalBackendTopologyPlacement> {
        Set(tabs.flatMap { workspace in
            workspace.panels.keys.map { surfaceID in
                TerminalBackendTopologyPlacement(
                    workspaceID: workspace.id,
                    surfaceID: surfaceID
                )
            }
        })
    }

    func presentationWorkspaceIDs() -> Set<UUID> {
        Set(tabs.map(\.id))
    }

    func frontendNativeBrowserSourceURL(surfaceID: SurfaceID) -> URL? {
        tabs.lazy.compactMap { workspace in
            guard let panel = workspace.panels[surfaceID.rawValue] as? BrowserPanel,
                  panel.endpointProvenance == .frontendNativeCanonical(surfaceID) else {
                return nil
            }
            return panel.currentURLForTabDuplication
                ?? panel.preferredURLStringForOmnibar().flatMap(URL.init(string:))
        }.first
    }

    func frontendNativeBrowserIsPresented(surfaceID: SurfaceID) -> Bool {
        tabs.contains { workspace in
            guard let panel = workspace.panels[surfaceID.rawValue] as? BrowserPanel else {
                return false
            }
            return panel.endpointProvenance == .frontendNativeCanonical(surfaceID)
        }
    }

    func installFrontendNativeBrowserClaimSourceURL(
        _ sourceURL: URL,
        surfaceID: SurfaceID
    ) {
        for workspace in tabs {
            guard let panel = workspace.panels[surfaceID.rawValue] as? BrowserPanel,
                  panel.endpointProvenance == .frontendNativeCanonical(surfaceID) else {
                continue
            }
            guard panel.currentURLForTabDuplication != sourceURL else { return }
            panel.navigateWithoutInsecureHTTPPrompt(
                to: sourceURL,
                recordTypedNavigation: false
            )
            return
        }
    }

    func prepareCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws -> TerminalBackendTopologyPreparedProjection {
        try preflightCanonicalTopology(snapshot, plan: plan)
        let state = try captureTopologyProjectionState()
        return TerminalBackendTopologyPreparedProjection(
            commit: { [weak self] in
                guard let self else { return }
                try self.commitCanonicalTopology(snapshot, plan: plan, state: state)
            },
            finalize: { [weak self] in
                guard let self else { return }
                self.finalizeCanonicalTopology(state)
                self.terminalClientComposition
                    .terminalBackendTopologyMutationCoordinator?
                    .canonicalProjectionDidInstall(
                        snapshot,
                        presentationID: self.terminalBackendProjectionPresentationID
                    )
                self.canonicalTopologyDidProject(snapshot)
            },
            rollback: { [weak self] in
                guard let self else { return }
                try self.rollbackCanonicalTopology(state)
            }
        )
    }

    private func commitCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan,
        state: TabManagerTopologyProjectionState
    ) throws {
        let browserResolver = TerminalBackendBrowserEndpointResolver(
            factory: terminalClientComposition.browserEndpointFactory
        )
        let previousTabs = state.previousTabs
        let previousSelection = state.previousSelection
        let previousGroups = state.previousGroups
        let previousByID = Dictionary(
            previousTabs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldGroupIDs = Dictionary(
            previousTabs.map { ($0.id, $0.groupId) },
            uniquingKeysWith: { first, _ in first }
        )

        let orderedTargets = plan.workspaces.flatMap { workspacePlan in
            orderedCanonicalSurfaces(in: workspacePlan).map {
                (workspaceID: workspacePlan.canonical.uuid.rawValue, surface: $0)
            }
        }

        var currentOwnerBySurface: [UUID: Workspace] = [:]
        for workspace in previousTabs {
            for surfaceID in workspace.panels.keys {
                guard currentOwnerBySurface.updateValue(workspace, forKey: surfaceID) == nil else {
                    throw TerminalBackendTopologyProjectionError.duplicatePlacement(
                        TerminalBackendTopologyPlacement(
                            workspaceID: workspace.id,
                            surfaceID: surfaceID
                        )
                    )
                }
            }
        }

        // Revalidate every typed endpoint before the first live detach. A local
        // BrowserPanel with the same UUID is still a client overlay unless its
        // provenance matches this exact daemon runtime.
        for target in orderedTargets {
            let surfaceID = target.surface.uuid.rawValue
            let expectedType = try panelType(for: target.surface)
            if let owner = currentOwnerBySurface[surfaceID],
               let panel = owner.panels[surfaceID] {
                let permitsCloudAdoption = owner.id == target.workspaceID
                    && permitsCloudTerminalAdoption(
                        panel: panel,
                        expectedType: expectedType,
                        workspaceID: target.workspaceID,
                        surfaceID: surfaceID
                    )
                guard panel.panelType.rawValue == expectedType.rawValue
                        || permitsCloudAdoption else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "canonical surface kind changed for an existing presentation"
                    )
                }
                if expectedType == .browser {
                    guard let browser = panel as? BrowserPanel else {
                        throw TerminalBackendTopologyProjectionError.missingSurface(surfaceID)
                    }
                    let endpoint = try browserResolver.endpoint(
                        authority: snapshot.authority,
                        surface: target.surface
                    )
                    try browserResolver.validateExisting(browser, endpoint: endpoint)
                }
            }
        }

        // Cross-workspace transfer retains the exact terminal or browser
        // presentation object and its backend runtime identity.
        var transfers: [UUID: Workspace.DetachedSurfaceTransfer] = [:]
        for target in orderedTargets {
            let surfaceID = target.surface.uuid.rawValue
            guard let source = currentOwnerBySurface[surfaceID],
                  source.id != target.workspaceID else { continue }
            source.isApplyingCanonicalTopologyProjection = true
            defer { source.isApplyingCanonicalTopologyProjection = false }
            let origin = TabManagerTopologyProjectionState.TerminalMovementOrigin(
                workspace: source,
                pane: source.paneId(forPanelId: surfaceID)
            )
            if source.panels[surfaceID] is BrowserPanel {
                state.browserMovementOrigins[surfaceID] = origin
            } else {
                state.terminalMovementOrigins[surfaceID] = origin
            }
            guard let transfer = source.detachSurface(
                panelId: surfaceID,
                publishLifecycleEvent: false
            ) else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "canonical surface transfer detach"
                )
            }
            transfers[surfaceID] = transfer
        }

        var canonicalWorkspaces: [Workspace] = []
        canonicalWorkspaces.reserveCapacity(plan.workspaces.count)
        for workspacePlan in plan.workspaces {
            let workspaceID = workspacePlan.canonical.uuid.rawValue
            let orderedSurfaces = orderedCanonicalSurfaces(in: workspacePlan)
            guard let firstSurface = orderedSurfaces.first else {
                // A browser-only canonical workspace has no Swift presentation
                // endpoint yet. Retire any old daemon presentation, but retain
                // local browser overlays in their separate client namespace.
                if let existing = previousByID[workspaceID] {
                    state.touch(existing)
                    existing.isApplyingCanonicalTopologyProjection = true
                    defer { existing.isApplyingCanonicalTopologyProjection = false }
                    let canonicalPresentationIDs = existing.panels.compactMap {
                        panelID, panel in
                        if panel is TerminalPanel { return panelID }
                        if let browser = panel as? BrowserPanel,
                           browser.endpointProvenance.canonicalSurfaceID != nil {
                            return panelID
                        }
                        return nil
                    }
                    for panelID in canonicalPresentationIDs {
                        try stageCanonicalPresentationRetirement(
                            panelID,
                            from: existing,
                            state: state
                        )
                    }
                    if !existing.panels.isEmpty {
                        canonicalWorkspaces.append(existing)
                    }
                }
                continue
            }
            let firstPane = try canonicalFirstPane(
                in: workspacePlan.screen.layout,
                panesByID: Dictionary(
                    uniqueKeysWithValues: workspacePlan.screen.panes.map {
                        ($0.uuid.rawValue, $0)
                    }
                )
            )
            let workspace: Workspace
            if let existing = previousByID[workspaceID] {
                workspace = existing
            } else if let transfer = transfers.removeValue(forKey: firstSurface.uuid.rawValue) {
                workspace = Workspace(
                    id: workspaceID,
                    title: workspacePlan.canonical.name,
                    initialDetachedSurface: transfer,
                    terminalClientComposition: terminalClientComposition,
                    initialTerminalPaneID: firstPane.uuid.rawValue,
                    isCanonicalTopologyProjection: true,
                    nativeSSHConnectionBroker: nativeSSHConnectionBroker
                )
                if let panel = transfer.panel as? TerminalPanel {
                    guard let origin = state.terminalMovementOrigins[panel.id] else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed(
                            "canonical terminal transfer origin"
                        )
                    }
                    state.terminalPlacementAdoptions.append(.init(
                        panel: panel,
                        sourceWorkspace: origin.workspace,
                        sourcePane: origin.pane,
                        destinationWorkspace: workspace,
                        workspaceID: workspaceID
                    ))
                } else if let panel = transfer.panel as? BrowserPanel {
                    guard let origin = state.browserMovementOrigins[panel.id] else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed(
                            "canonical browser transfer origin"
                        )
                    }
                    state.browserPlacementAdoptions.append(.init(
                        panel: panel,
                        sourceWorkspace: origin.workspace,
                        sourcePane: origin.pane,
                        destinationWorkspace: workspace
                    ))
                }
            } else {
                switch try panelType(for: firstSurface) {
                case .terminal:
                    workspace = Workspace(
                        id: workspaceID,
                        title: workspacePlan.canonical.name,
                        terminalClientComposition: terminalClientComposition,
                        initialTerminalSurfaceID: firstSurface.uuid.rawValue,
                        initialTerminalPaneID: firstPane.uuid.rawValue,
                        isCanonicalTopologyProjection: true,
                        nativeSSHConnectionBroker: nativeSSHConnectionBroker
                    )
                    if let panel = workspace.panels[firstSurface.uuid.rawValue] as? TerminalPanel {
                        state.terminalCreations.append(.init(
                            panel: panel,
                            workspace: workspace
                        ))
                    }
                case .browser:
                    let endpoint = try browserResolver.endpoint(
                        authority: snapshot.authority,
                        surface: firstSurface
                    )
                    let panel = try browserResolver.materialize(
                        endpoint,
                        workspaceID: workspaceID
                    )
                    workspace = Workspace(
                        id: workspaceID,
                        title: workspacePlan.canonical.name,
                        initialCanonicalBrowserPanel: panel,
                        terminalClientComposition: terminalClientComposition,
                        initialTerminalPaneID: firstPane.uuid.rawValue,
                        isCanonicalTopologyProjection: true,
                        nativeSSHConnectionBroker: nativeSSHConnectionBroker
                    )
                    guard workspace.panels[panel.id] === panel else {
                        panel.close()
                        throw TerminalBackendTopologyProjectionError.missingSurface(panel.id)
                    }
                    state.browserCreations.append(.init(
                        panel: panel,
                        workspace: workspace
                    ))
                default:
                    throw TerminalBackendTopologyProjectionError.unsupportedSurfaceKind(
                        surfaceID: firstSurface.uuid.rawValue,
                        kind: firstSurface.kind
                    )
                }
            }
            state.touch(workspace)

            workspace.isApplyingCanonicalTopologyProjection = true
            defer { workspace.isApplyingCanonicalTopologyProjection = false }
            workspace.groupId = oldGroupIDs[workspace.id] ?? nil

            guard let stagingPane = workspace.bonsplitController.allPaneIds.first else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "canonical workspace staging pane"
                )
            }
            for surface in orderedSurfaces {
                let surfaceID = surface.uuid.rawValue
                let expectedType = try panelType(for: surface)
                var cloudLoadingAdoption: (
                    pane: Bonsplit.PaneID,
                    index: Int,
                    transfer: Workspace.DetachedSurfaceTransfer
                )?
                if let panel = workspace.panels[surfaceID],
                   panel.panelType.rawValue != expectedType.rawValue,
                   permitsCloudTerminalAdoption(
                       panel: panel,
                       expectedType: expectedType,
                       workspaceID: workspaceID,
                       surfaceID: surfaceID
                   ) {
                    guard let pane = workspace.paneId(forPanelId: surfaceID),
                          let tabID = workspace.surfaceIdFromPanelId(surfaceID),
                          let index = workspace.bonsplitController.tabs(inPane: pane)
                            .firstIndex(where: { $0.id == tabID }),
                          let transfer = workspace.detachSurface(
                            panelId: surfaceID,
                            publishLifecycleEvent: false
                          ) else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed(
                            "canonical cloud terminal adoption staging"
                        )
                    }
                    cloudLoadingAdoption = (pane, index, transfer)
                    state.retirements.append(.init(
                        workspace: workspace,
                        pane: pane,
                        index: index,
                        transfer: transfer
                    ))
                }
                if let panel = workspace.panels[surfaceID] {
                    guard panel.panelType.rawValue == expectedType.rawValue else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed(
                            "canonical surface kind changed during projection"
                        )
                    }
                    continue
                }
                if let transfer = transfers.removeValue(forKey: surfaceID) {
                    guard workspace.attachDetachedSurface(
                        transfer,
                        inPane: stagingPane,
                        focus: false,
                        publishLifecycleEvent: false,
                        adoptCanonicalTerminalPlacement: false
                    ) != nil else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed(
                            "canonical terminal transfer attach"
                        )
                    }
                    if let panel = transfer.panel as? TerminalPanel {
                        guard let origin = state.terminalMovementOrigins[panel.id] else {
                            throw TerminalBackendTopologyProjectionError.projectionFailed(
                                "canonical terminal transfer origin"
                            )
                        }
                        state.terminalPlacementAdoptions.append(.init(
                            panel: panel,
                            sourceWorkspace: origin.workspace,
                            sourcePane: origin.pane,
                            destinationWorkspace: workspace,
                            workspaceID: workspaceID
                        ))
                    } else if let panel = transfer.panel as? BrowserPanel {
                        guard let origin = state.browserMovementOrigins[panel.id] else {
                            throw TerminalBackendTopologyProjectionError.projectionFailed(
                                "canonical browser transfer origin"
                            )
                        }
                        state.browserPlacementAdoptions.append(.init(
                            panel: panel,
                            sourceWorkspace: origin.workspace,
                            sourcePane: origin.pane,
                            destinationWorkspace: workspace
                        ))
                    }
                } else if expectedType.rawValue == PanelType.terminal.rawValue {
                    guard let panel = workspace.newTerminalSurface(
                        inPane: stagingPane,
                        focus: false,
                        autoRefreshMetadata: false,
                        preserveFocusWhenUnfocused: true,
                        restoredSurfaceId: surfaceID,
                        creationOrigin: .sessionRestore,
                        publishLifecycleEvent: false
                    ) else {
                        throw TerminalBackendTopologyProjectionError.missingSurface(surfaceID)
                    }
                    if let cloudLoadingAdoption {
                        guard let stagedRetirementIndex = state.retirements.lastIndex(where: {
                            $0.transfer.panelId == surfaceID
                                && $0.workspace === workspace
                        }) else {
                            throw TerminalBackendTopologyProjectionError.projectionFailed(
                                "canonical cloud terminal adoption retirement"
                            )
                        }
                        state.retirements.remove(at: stagedRetirementIndex)
                        panel.adoptStableSurfaceId(
                            cloudLoadingAdoption.transfer.panel.stableSurfaceId
                        )
                        state.cloudTerminalAdoptions.append(.init(
                            workspace: workspace,
                            pane: cloudLoadingAdoption.pane,
                            index: cloudLoadingAdoption.index,
                            loadingTransfer: cloudLoadingAdoption.transfer,
                            terminalPanel: panel
                        ))
                    } else {
                        state.terminalCreations.append(.init(
                            panel: panel,
                            workspace: workspace
                        ))
                    }
                } else if expectedType == .browser {
                    let endpoint = try browserResolver.endpoint(
                        authority: snapshot.authority,
                        surface: surface
                    )
                    let panel = try browserResolver.materialize(
                        endpoint,
                        workspaceID: workspaceID
                    )
                    guard workspace.attachCanonicalBrowserEndpointPanel(
                        panel,
                        inPane: stagingPane
                    ) != nil else {
                        panel.close()
                        throw TerminalBackendTopologyProjectionError.missingSurface(surfaceID)
                    }
                    state.browserCreations.append(.init(
                        panel: panel,
                        workspace: workspace
                    ))
                } else {
                    throw TerminalBackendTopologyProjectionError.missingSurface(surfaceID)
                }
            }

            let targetSurfaceIDs = Set(orderedSurfaces.map { $0.uuid.rawValue })
            let obsoleteCanonicalPresentationIDs: [UUID] = workspace.panels.compactMap { panelID, panel in
                guard !targetSurfaceIDs.contains(panelID) else { return nil }
                if panel is TerminalPanel { return panelID }
                if let browser = panel as? BrowserPanel,
                   browser.endpointProvenance.canonicalSurfaceID != nil {
                    return panelID
                }
                return nil
            }
            for panelID in obsoleteCanonicalPresentationIDs {
                try stageCanonicalPresentationRetirement(
                    panelID,
                    from: workspace,
                    state: state
                )
            }

            let authoritativeTree = try makeAuthoritativeTree(
                workspacePlan,
                in: workspace
            )
            try workspace.bonsplitController.validateAuthoritativeTree(authoritativeTree)
            _ = try workspace.bonsplitController.applyAuthoritativeTree(authoritativeTree)
            for surface in orderedSurfaces {
                applyCanonicalSurfaceName(surface, in: workspace)
            }
            // The daemon name is an explicit layer, independent of OSC/process
            // titles. An empty canonical name clears it and reveals processTitle.
            let canonicalWorkspaceName = workspacePlan.canonical.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = workspace.setCustomTitle(
                canonicalWorkspaceName.isEmpty ? nil : canonicalWorkspaceName,
                source: .backend
            )
            canonicalWorkspaces.append(workspace)
        }

        guard transfers.isEmpty else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "unconsumed canonical surface transfer"
            )
        }

        let canonicalWorkspaceIDs = Set(plan.workspaces.map { $0.canonical.uuid.rawValue })
        var clientOnlyWorkspaces: [Workspace] = []
        for workspace in previousTabs where !canonicalWorkspaceIDs.contains(workspace.id) {
            state.touch(workspace)
            workspace.isApplyingCanonicalTopologyProjection = true
            defer { workspace.isApplyingCanonicalTopologyProjection = false }
            let canonicalPresentationIDs: [UUID] = workspace.panels.compactMap { panelID, panel in
                if panel is TerminalPanel { return panelID }
                if let browser = panel as? BrowserPanel,
                   browser.endpointProvenance.canonicalSurfaceID != nil {
                    return panelID
                }
                return nil
            }
            for panelID in canonicalPresentationIDs {
                try stageCanonicalPresentationRetirement(
                    panelID,
                    from: workspace,
                    state: state
                )
            }
            if !workspace.panels.isEmpty {
                clientOnlyWorkspaces.append(workspace)
            }
        }

        let projectedTabs = canonicalWorkspaces + clientOnlyWorkspaces
        let projectedObjects = Set(projectedTabs.map(ObjectIdentifier.init))
        let previousObjects = Set(previousTabs.map(ObjectIdentifier.init))
        for workspace in previousTabs where !projectedObjects.contains(ObjectIdentifier(workspace)) {
            unwireClosedBrowserTracking(for: workspace)
            workspace.owningTabManager = nil
        }
        for workspace in projectedTabs where !previousObjects.contains(ObjectIdentifier(workspace)) {
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

    private func preflightCanonicalTopology(
        _ snapshot: TopologySnapshot,
        plan: TerminalBackendTopologyProjectionPlan
    ) throws {
        let browserResolver = TerminalBackendBrowserEndpointResolver(
            factory: terminalClientComposition.browserEndpointFactory
        )
        var existingPanels: [UUID: any Panel] = [:]
        var existingPanelWorkspaceIDs: [UUID: UUID] = [:]
        var existingWorkspaceIDs: Set<UUID> = []
        for workspace in tabs {
            guard existingWorkspaceIDs.insert(workspace.id).inserted else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "one Swift presentation contains duplicate workspace identities"
                )
            }
            for (panelID, panel) in workspace.panels {
                guard existingPanels.updateValue(panel, forKey: panelID) == nil else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "one surface is presented more than once in this window"
                    )
                }
                existingPanelWorkspaceIDs[panelID] = workspace.id
            }
        }

        var canonicalSurfaceIDs: Set<UUID> = []
        var canonicalWorkspaceIDs: Set<UUID> = []
        for workspacePlan in plan.workspaces {
            guard canonicalWorkspaceIDs.insert(workspacePlan.canonical.uuid.rawValue).inserted else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "one canonical workspace appears more than once"
                )
            }
            let allSurfaces = workspacePlan.screens.flatMap { screen in
                screen.panes.flatMap(\.tabs)
            }
            let allSurfacesByID = Dictionary(
                uniqueKeysWithValues: allSurfaces.map { ($0.uuid.rawValue, $0) }
            )
            // Validate every browser descriptor, including dormant screens,
            // without allocating a presentation for dormant value state.
            for surface in allSurfaces {
                if try panelType(for: surface) == .browser {
                    let endpoint = try browserResolver.endpoint(
                        authority: snapshot.authority,
                        surface: surface
                    )
                    if let existing = existingPanels[surface.uuid.rawValue] {
                        guard let browser = existing as? BrowserPanel else {
                            throw TerminalBackendTopologyProjectionError.projectionFailed(
                                "canonical surface kind changed for an existing presentation"
                            )
                        }
                        try browserResolver.validateExisting(browser, endpoint: endpoint)
                    }
                }
            }
            let orderedSurfaces = orderedCanonicalSurfaces(in: workspacePlan)
            guard !orderedSurfaces.isEmpty else { continue }
            _ = try canonicalFirstPane(
                in: workspacePlan.screen.layout,
                panesByID: Dictionary(
                    uniqueKeysWithValues: workspacePlan.screen.panes.map {
                        ($0.uuid.rawValue, $0)
                    }
                )
            )
            for surface in orderedSurfaces {
                let surfaceID = surface.uuid.rawValue
                guard canonicalSurfaceIDs.insert(surfaceID).inserted else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "one canonical surface appears more than once"
                    )
                }
                let expectedType = try panelType(for: surface)
                if let existing = existingPanels[surfaceID] {
                    let permitsCloudAdoption = existingPanelWorkspaceIDs[surfaceID]
                        == workspacePlan.canonical.uuid.rawValue
                        && permitsCloudTerminalAdoption(
                            panel: existing,
                            expectedType: expectedType,
                            workspaceID: workspacePlan.canonical.uuid.rawValue,
                            surfaceID: surfaceID
                        )
                    guard existing.panelType.rawValue == expectedType.rawValue
                            || permitsCloudAdoption else {
                        throw TerminalBackendTopologyProjectionError.projectionFailed(
                            "canonical surface kind changed for an existing presentation"
                        )
                    }
                    if expectedType == .browser {
                        guard let browser = existing as? BrowserPanel else {
                            throw TerminalBackendTopologyProjectionError.missingSurface(surfaceID)
                        }
                        let endpoint = try browserResolver.endpoint(
                            authority: snapshot.authority,
                            surface: surface
                        )
                        try browserResolver.validateExisting(browser, endpoint: endpoint)
                    }
                } else if expectedType == .browser {
                    let endpoint = try browserResolver.endpoint(
                        authority: snapshot.authority,
                        surface: surface
                    )
                    try browserResolver.validateMaterialization(endpoint)
                } else if expectedType.rawValue != PanelType.terminal.rawValue {
                    throw TerminalBackendTopologyProjectionError.missingSurface(surfaceID)
                }
            }
            let selectedSurfaceIDs = Set(orderedSurfaces.map { $0.uuid.rawValue })
            for dormantSurfaceID in workspacePlan.allCanonicalSurfaceIDs
                .subtracting(selectedSurfaceIDs) {
                guard let dormantSurface = allSurfacesByID[dormantSurfaceID],
                      let dormantPanel = existingPanels[dormantSurfaceID] else {
                    continue
                }
                let expectedType = try panelType(for: dormantSurface)
                let permitsCloudAdoption = existingPanelWorkspaceIDs[dormantSurfaceID]
                    == workspacePlan.canonical.uuid.rawValue
                    && permitsCloudTerminalAdoption(
                        panel: dormantPanel,
                        expectedType: expectedType,
                        workspaceID: workspacePlan.canonical.uuid.rawValue,
                        surfaceID: dormantSurfaceID
                    )
                guard dormantPanel.panelType == expectedType || permitsCloudAdoption else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "dormant canonical surface kind changed for an existing presentation"
                    )
                }
                if expectedType == .browser {
                    guard let browser = dormantPanel as? BrowserPanel else {
                        throw TerminalBackendTopologyProjectionError.missingSurface(dormantSurfaceID)
                    }
                    let endpoint = try browserResolver.endpoint(
                        authority: snapshot.authority,
                        surface: dormantSurface
                    )
                    try browserResolver.validateExisting(browser, endpoint: endpoint)
                }
            }
        }
    }

    private func permitsCloudTerminalAdoption(
        panel: any Panel,
        expectedType: PanelType,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> Bool {
        guard panel is CloudVMLoadingPanel,
              expectedType == .terminal else {
            return false
        }
        return terminalClientComposition.terminalBackendTopologyAdoptionRegistry?
            .permitsCloudTerminalAdoption(
                workspaceID: workspaceID,
                surfaceID: surfaceID
            ) == true
    }

    private func captureTopologyProjectionState() throws -> TabManagerTopologyProjectionState {
        let previousTabs = tabs
        var snapshots: [UUID: TabManagerTopologyProjectionState.WorkspaceSnapshot] = [:]
        var owners: [UUID: Workspace] = [:]
        for workspace in previousTabs {
            snapshots[workspace.id] = TabManagerTopologyProjectionState.WorkspaceSnapshot(
                workspace: workspace,
                panels: workspace.panels,
                title: workspace.title,
                processTitle: workspace.processTitle,
                customTitle: workspace.customTitle,
                customTitleSource: workspace.customTitleSource,
                panelTitles: workspace.panelTitles,
                panelCustomTitles: workspace.panelCustomTitles,
                panelCustomTitleSources: workspace.panelCustomTitleSources,
                groupID: workspace.groupId,
                tree: try captureAuthoritativeTree(in: workspace)
            )
            for panelID in workspace.panels.keys {
                guard owners.updateValue(workspace, forKey: panelID) == nil else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "one local surface is owned by multiple workspaces"
                    )
                }
            }
        }
        return TabManagerTopologyProjectionState(
            previousTabs: previousTabs,
            previousSelection: selectedTabId,
            previousGroups: workspaceGroups,
            workspaceSnapshots: snapshots,
            originalPanelOwners: owners
        )
    }

    private func captureAuthoritativeTree(
        in workspace: Workspace
    ) throws -> BonsplitAuthoritativeTree {
        let controller = workspace.bonsplitController
        let root = try captureAuthoritativeNode(
            controller.treeSnapshot(),
            controller: controller
        )
        let focusedPane = controller.focusedPaneId.map {
            BonsplitAuthoritativeTree.PaneReference.pane($0)
        } ?? .none
        let zoomedPane = controller.zoomedPaneId.map {
            BonsplitAuthoritativeTree.PaneReference.pane($0)
        } ?? .none
        return BonsplitAuthoritativeTree(
            root: root,
            focusedPane: focusedPane,
            zoomedPane: zoomedPane
        )
    }

    private func captureAuthoritativeNode(
        _ node: ExternalTreeNode,
        controller: BonsplitController
    ) throws -> BonsplitAuthoritativeTree.Node {
        switch node {
        case .pane(let pane):
            guard let paneUUID = UUID(uuidString: pane.id) else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "local pane identity is invalid"
                )
            }
            let tabs = try pane.tabs.map { tab -> TabID in
                guard let tabUUID = UUID(uuidString: tab.id) else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "local surface identity is invalid"
                    )
                }
                return TabID(uuid: tabUUID)
            }
            guard !tabs.isEmpty else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "local pane has no presentation tabs"
                )
            }
            let paneID = Bonsplit.PaneID(id: paneUUID)
            let selection: BonsplitAuthoritativeTree.TabSelection
            if let selected = pane.selectedTabId.flatMap({ UUID(uuidString: $0) }),
               tabs.contains(TabID(uuid: selected)) {
                selection = .tab(TabID(uuid: selected))
            } else {
                selection = .tab(tabs[0])
            }
            return .pane(BonsplitAuthoritativeTree.Pane(
                id: paneID,
                tabs: tabs,
                selection: selection,
                fullWidthTabMode: .value(controller.isFullWidthTabMode(inPane: paneID))
            ))

        case .split(let split):
            guard let splitID = UUID(uuidString: split.id) else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "local split identity is invalid"
                )
            }
            return .split(BonsplitAuthoritativeTree.Split(
                id: splitID,
                orientation: split.orientation == "horizontal" ? .horizontal : .vertical,
                ratio: split.dividerPosition,
                first: try captureAuthoritativeNode(split.first, controller: controller),
                second: try captureAuthoritativeNode(split.second, controller: controller)
            ))
        }
    }

    private func stageCanonicalPresentationRetirement(
        _ panelID: UUID,
        from workspace: Workspace,
        state: TabManagerTopologyProjectionState
    ) throws {
        guard let panel = workspace.panels[panelID],
              panel is TerminalPanel || (panel as? BrowserPanel).map({ browser in
                  if browser.endpointProvenance.canonicalSurfaceID != nil { return true }
                  return false
              }) == true,
              let tabID = workspace.surfaceIdFromPanelId(panelID),
              let pane = workspace.paneId(forPanelId: panelID),
              let index = workspace.bonsplitController.tabs(inPane: pane)
                .firstIndex(where: { $0.id == tabID }),
              let transfer = workspace.detachSurface(
                  panelId: panelID,
                  publishLifecycleEvent: false
              ) else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "canonical presentation retirement staging"
            )
        }
        state.retirements.append(.init(
            workspace: workspace,
            pane: pane,
            index: index,
            transfer: transfer
        ))
    }

    private func finalizeCanonicalTopology(
        _ state: TabManagerTopologyProjectionState
    ) {
        for adoption in state.cloudTerminalAdoptions {
            adoption.workspace.publishCmuxSurfaceClosed(
                adoption.loadingTransfer.panelId,
                paneId: adoption.pane,
                panel: adoption.loadingTransfer.panel,
                origin: "terminal_backend_cloud_adoption"
            )
            adoption.workspace.publishCmuxSurfaceCreated(
                adoption.terminalPanel.id,
                paneId: adoption.workspace.paneId(forPanelId: adoption.terminalPanel.id),
                kind: "terminal",
                origin: "terminal_backend_cloud_adoption",
                focused: false
            )
            adoption.loadingTransfer.panel.close()
            _ = terminalClientComposition.terminalBackendTopologyAdoptionRegistry?
                .consumeCloudTerminalAdoption(
                    workspaceID: adoption.workspace.id,
                    surfaceID: adoption.terminalPanel.id
                )
        }
        state.cloudTerminalAdoptions.removeAll()
        for adoption in state.terminalPlacementAdoptions {
            adoption.panel.finalizeStagedCanonicalWorkspaceId(adoption.workspaceID)
            adoption.sourceWorkspace.publishCmuxSurfaceClosed(
                adoption.panel.id,
                paneId: adoption.sourcePane,
                panel: adoption.panel,
                origin: "terminal_backend_topology"
            )
            adoption.destinationWorkspace.publishCmuxSurfaceCreated(
                adoption.panel.id,
                paneId: adoption.destinationWorkspace.paneId(forPanelId: adoption.panel.id),
                kind: "terminal",
                origin: "terminal_backend_topology",
                focused: false
            )
            AppDelegate.shared?.notificationStore?.rebindSurfaceNotifications(
                fromTabId: adoption.sourceWorkspace.id,
                toTabId: adoption.workspaceID,
                surfaceId: adoption.panel.id
            )
        }
        state.terminalPlacementAdoptions.removeAll()
        state.terminalMovementOrigins.removeAll()
        for adoption in state.browserPlacementAdoptions {
            adoption.sourceWorkspace.publishCmuxSurfaceClosed(
                adoption.panel.id,
                paneId: adoption.sourcePane,
                panel: adoption.panel,
                origin: "terminal_backend_topology"
            )
            adoption.destinationWorkspace.publishCmuxSurfaceCreated(
                adoption.panel.id,
                paneId: adoption.destinationWorkspace.paneId(forPanelId: adoption.panel.id),
                kind: "browser",
                origin: "terminal_backend_topology",
                focused: false
            )
            AppDelegate.shared?.notificationStore?.rebindSurfaceNotifications(
                fromTabId: adoption.sourceWorkspace.id,
                toTabId: adoption.destinationWorkspace.id,
                surfaceId: adoption.panel.id
            )
        }
        state.browserPlacementAdoptions.removeAll()
        state.browserMovementOrigins.removeAll()
        for creation in state.terminalCreations {
            creation.workspace.publishCmuxSurfaceCreated(
                creation.panel.id,
                paneId: creation.workspace.paneId(forPanelId: creation.panel.id),
                kind: "terminal",
                origin: "terminal_backend_topology",
                focused: false
            )
        }
        state.terminalCreations.removeAll()
        for creation in state.browserCreations {
            creation.workspace.publishCmuxSurfaceCreated(
                creation.panel.id,
                paneId: creation.workspace.paneId(forPanelId: creation.panel.id),
                kind: "browser",
                origin: "terminal_backend_topology",
                focused: false
            )
        }
        state.browserCreations.removeAll()
        for retirement in state.retirements {
            retirement.workspace.publishCmuxSurfaceClosed(
                retirement.transfer.panelId,
                paneId: retirement.pane,
                panel: retirement.transfer.panel,
                origin: "terminal_backend_topology"
            )
            if let panel = retirement.transfer.panel as? TerminalPanel {
                panel.surface.detachExternalPresentationPreservingCanonicalTerminal()
            }
            retirement.transfer.panel.close()
        }
        state.retirements.removeAll()
        for workspace in tabs {
            workspace.rememberBackendCanonicalTabPlacementBaseline()
        }
        let liveWorkspaceIdentities = Set(tabs.map(ObjectIdentifier.init))
        for workspace in state.touchedWorkspaces
            where !liveWorkspaceIdentities.contains(ObjectIdentifier(workspace))
                && workspace.panels.isEmpty {
            workspace.teardownAllPanels()
        }
    }

    private func rollbackCanonicalTopology(
        _ state: TabManagerTopologyProjectionState
    ) throws {
        var rollbackFailures: [String] = []
        func recordFailure(_ message: String) {
            rollbackFailures.append(message)
        }
        var allWorkspaces: [Workspace] = []
        var allWorkspaceIdentities: Set<ObjectIdentifier> = []
        for workspace in state.previousTabs + state.touchedWorkspaces + tabs {
            if allWorkspaceIdentities.insert(ObjectIdentifier(workspace)).inserted {
                allWorkspaces.append(workspace)
            }
        }
        for workspace in allWorkspaces {
            workspace.isApplyingCanonicalTopologyProjection = true
        }
        defer {
            for workspace in allWorkspaces {
                workspace.isApplyingCanonicalTopologyProjection = false
            }
        }

        for adoption in state.cloudTerminalAdoptions.reversed() {
            if adoption.workspace.panels[adoption.terminalPanel.id]
                === adoption.terminalPanel {
                guard let terminalTransfer = adoption.workspace.detachSurface(
                    panelId: adoption.terminalPanel.id,
                    publishLifecycleEvent: false
                ) else {
                    recordFailure("adopted cloud terminal could not be detached during rollback")
                    continue
                }
                adoption.terminalPanel.surface
                    .detachExternalPresentationPreservingCanonicalTerminal()
                terminalTransfer.panel.close()
            }
            let rollbackPane = adoption.workspace.bonsplitController.allPaneIds
                .contains(adoption.pane)
                ? adoption.pane
                : adoption.workspace.bonsplitController.allPaneIds.first
            guard let rollbackPane,
                  adoption.workspace.attachDetachedSurface(
                    adoption.loadingTransfer,
                    inPane: rollbackPane,
                    atIndex: adoption.index,
                    focus: false,
                    publishLifecycleEvent: false,
                    adoptCanonicalTerminalPlacement: false
                  ) == adoption.loadingTransfer.panelId else {
                recordFailure("cloud loading surface could not be restored during rollback")
                continue
            }
        }
        state.cloudTerminalAdoptions.removeAll()

        for retirement in state.retirements {
            let pane = retirement.workspace.bonsplitController.allPaneIds.contains(retirement.pane)
                ? retirement.pane
                : retirement.workspace.bonsplitController.allPaneIds.first
            guard let pane else {
                recordFailure("retired presentation has no rollback staging pane")
                continue
            }
            guard retirement.workspace.attachDetachedSurface(
                retirement.transfer,
                inPane: pane,
                atIndex: retirement.index,
                focus: false,
                publishLifecycleEvent: false,
                adoptCanonicalTerminalPlacement: false
            ) == retirement.transfer.panelId else {
                recordFailure("retired presentation could not be reattached during rollback")
                continue
            }
        }
        state.retirements.removeAll()

        var currentOwners: [UUID: Workspace] = [:]
        for workspace in allWorkspaces {
            for panelID in workspace.panels.keys {
                currentOwners[panelID] = workspace
            }
        }
        for (panelID, originalOwner) in state.originalPanelOwners {
            guard let owner = currentOwners[panelID], owner !== originalOwner else { continue }
            guard let transfer = owner.detachSurface(
                panelId: panelID,
                publishLifecycleEvent: false
            ) else {
                recordFailure("moved terminal could not be detached during rollback")
                continue
            }
            guard let pane = transfer.sourcePaneId.flatMap({ sourcePane in
                originalOwner.bonsplitController.allPaneIds.contains(sourcePane)
                    ? sourcePane
                    : nil
            }) ?? originalOwner.bonsplitController.allPaneIds.first else {
                recordFailure("moved terminal has no rollback staging pane")
                continue
            }
            guard originalOwner.attachDetachedSurface(
                transfer,
                inPane: pane,
                atIndex: transfer.sourceIndex,
                focus: false,
                publishLifecycleEvent: false,
                adoptCanonicalTerminalPlacement: false
            ) == panelID else {
                recordFailure("moved terminal could not be reattached to its original workspace")
                continue
            }
            currentOwners[panelID] = originalOwner
        }

        for workspace in allWorkspaces {
            let createdPanelIDs = workspace.panels.keys.filter {
                state.originalPanelOwners[$0] == nil
            }
            for panelID in createdPanelIDs {
                if let panel = workspace.panels[panelID] as? TerminalPanel {
                    panel.surface.detachExternalPresentationPreservingCanonicalTerminal()
                }
                guard workspace.closePanel(panelID, force: true),
                      workspace.panels[panelID] == nil else {
                    recordFailure("created terminal could not be removed during rollback")
                    continue
                }
            }
        }

        for snapshot in state.workspaceSnapshots.values {
            do {
                try snapshot.workspace.bonsplitController.validateAuthoritativeTree(snapshot.tree)
                _ = try snapshot.workspace.bonsplitController.applyAuthoritativeTree(snapshot.tree)
            } catch {
                recordFailure("original pane tree could not be restored: \(error.localizedDescription)")
            }
            snapshot.workspace.processTitle = snapshot.processTitle
            snapshot.workspace.customTitle = snapshot.customTitle
            snapshot.workspace.customTitleSource = snapshot.customTitleSource
            snapshot.workspace.title = snapshot.title
            snapshot.workspace.panelTitles = snapshot.panelTitles
            snapshot.workspace.panelCustomTitles = snapshot.panelCustomTitles
            snapshot.workspace.panelCustomTitleSources = snapshot.panelCustomTitleSources
            for (panelID, panel) in snapshot.workspace.panels {
                guard let tabID = snapshot.workspace.surfaceIdFromPanelId(panelID) else { continue }
                let fallback = snapshot.panelTitles[panelID] ?? panel.displayTitle
                snapshot.workspace.bonsplitController.updateTab(
                    tabID,
                    title: snapshot.workspace.resolvedPanelTitle(
                        panelId: panelID,
                        fallback: fallback
                    ),
                    hasCustomTitle: snapshot.panelCustomTitles[panelID] != nil
                )
            }
            snapshot.workspace.groupId = snapshot.groupID
        }

        let currentTabs = tabs
        let previousIdentities = Set(state.previousTabs.map(ObjectIdentifier.init))
        let currentIdentities = Set(currentTabs.map(ObjectIdentifier.init))
        for workspace in currentTabs where !previousIdentities.contains(ObjectIdentifier(workspace)) {
            unwireClosedBrowserTracking(for: workspace)
            workspace.owningTabManager = nil
        }
        for workspace in state.previousTabs where !currentIdentities.contains(ObjectIdentifier(workspace)) {
            workspace.owningTabManager = self
            wireClosedBrowserTracking(for: workspace)
        }
        tabs = state.previousTabs
        workspaceGroups = state.previousGroups
        selectedTabId = state.previousSelection

        if tabs.count != state.previousTabs.count
            || !zip(tabs, state.previousTabs).allSatisfy({ pair in
                pair.0 === pair.1
            }) {
            recordFailure("workspace object order changed during rollback")
        }
        if workspaceGroups != state.previousGroups {
            recordFailure("workspace groups changed during rollback")
        }
        if selectedTabId != state.previousSelection {
            recordFailure("workspace selection changed during rollback")
        }
        for snapshot in state.workspaceSnapshots.values {
            let workspace = snapshot.workspace
            if Set(workspace.panels.keys) != Set(snapshot.panels.keys) {
                recordFailure("workspace panel set changed during rollback")
            }
            for (panelID, originalPanel) in snapshot.panels {
                guard let restoredPanel = workspace.panels[panelID],
                      restoredPanel === originalPanel else {
                    recordFailure("workspace panel identity changed during rollback")
                    continue
                }
                guard workspace.surfaceIdFromPanelId(panelID) != nil else {
                    recordFailure("workspace panel lost its Bonsplit tab binding during rollback")
                    continue
                }
            }
            do {
                if try captureAuthoritativeTree(in: workspace) != snapshot.tree {
                    recordFailure("pane identity, order, focus, or zoom changed during rollback")
                }
            } catch {
                recordFailure("restored pane tree could not be inspected: \(error.localizedDescription)")
            }
            if workspace.title != snapshot.title
                || workspace.processTitle != snapshot.processTitle
                || workspace.customTitle != snapshot.customTitle
                || workspace.customTitleSource != snapshot.customTitleSource
                || workspace.panelTitles != snapshot.panelTitles
                || workspace.panelCustomTitles != snapshot.panelCustomTitles
                || workspace.panelCustomTitleSources != snapshot.panelCustomTitleSources
                || workspace.groupId != snapshot.groupID {
                recordFailure("workspace title or grouping metadata changed during rollback")
            }
        }

        for workspace in allWorkspaces
            where !previousIdentities.contains(ObjectIdentifier(workspace)) {
            workspace.teardownAllPanels()
        }
        state.terminalPlacementAdoptions.removeAll()
        state.terminalCreations.removeAll()
        state.terminalMovementOrigins.removeAll()
        state.browserPlacementAdoptions.removeAll()
        state.browserCreations.removeAll()
        state.browserMovementOrigins.removeAll()
        if !rollbackFailures.isEmpty {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                rollbackFailures.joined(separator: "; ")
            )
        }
    }

    private func orderedCanonicalSurfaces(
        in plan: TerminalBackendTopologyProjectionPlan.Workspace
    ) -> [CanonicalSurface] {
        let panesByID = Dictionary(
            uniqueKeysWithValues: plan.screen.panes.map { ($0.uuid.rawValue, $0) }
        )
        var result: [CanonicalSurface] = []
        appendCanonicalSurfaces(
            in: plan.screen.layout,
            panesByID: panesByID,
            to: &result
        )
        return result
    }

    private func appendCanonicalSurfaces(
        in layout: CanonicalLayout,
        panesByID: [UUID: CanonicalPane],
        to result: inout [CanonicalSurface]
    ) {
        switch layout {
        case .leaf(_, let paneUUID):
            if let pane = panesByID[paneUUID.rawValue] {
                result.append(contentsOf: pane.tabs.filter {
                    shouldProjectCanonicalSurface($0)
                })
            }
        case .split(_, _, let first, let second):
            appendCanonicalSurfaces(in: first, panesByID: panesByID, to: &result)
            appendCanonicalSurfaces(in: second, panesByID: panesByID, to: &result)
        }
    }

    private func makeAuthoritativeTree(
        _ plan: TerminalBackendTopologyProjectionPlan.Workspace,
        in workspace: Workspace
    ) throws -> BonsplitAuthoritativeTree {
        let panesByID = Dictionary(
            uniqueKeysWithValues: plan.screen.panes.map { ($0.uuid.rawValue, $0) }
        )
        let canonicalSurfaceIDs = plan.allCanonicalSurfaceIDs
        let canonicalTabIDs = Set(canonicalSurfaceIDs.compactMap {
            workspace.surfaceIdFromPanelId($0)
        })
        let canonicalPaneIDs = Set(plan.screen.panes.map { $0.uuid.rawValue })
        let canonicalPaneBySurface = Dictionary(
            uniqueKeysWithValues: plan.screen.panes.flatMap { pane in
                pane.tabs.map { ($0.uuid.rawValue, pane.uuid.rawValue) }
            }
        )
        let existingTree = workspace.bonsplitController.treeSnapshot()
        var overlaysByCanonicalPane: [UUID: [TerminalBackendClientOverlayTabPlacement]] = [:]
        var standaloneOverlayTabs: Set<TabID> = []
        for pane in existingPanes(in: existingTree) {
            guard let existingPaneID = UUID(uuidString: pane.id) else { continue }
            let paneTabIDs = pane.tabs.compactMap { tab -> TabID? in
                guard let tabID = UUID(uuidString: tab.id) else { return nil }
                return TabID(uuid: tabID)
            }
            let overlayTabIDs = paneTabIDs.filter { tabID in
                guard let panelID = workspace.panelIdFromSurfaceId(tabID),
                      let panel = workspace.panels[panelID] else { return false }
                return !(panel is TerminalPanel) && !canonicalSurfaceIDs.contains(panelID)
            }
            guard !overlayTabIDs.isEmpty else { continue }
            let overlays = overlayTabIDs.compactMap { tabID -> TerminalBackendClientOverlayTabPlacement? in
                guard let index = paneTabIDs.firstIndex(of: tabID) else { return nil }
                let preceding = paneTabIDs[..<index].last(where: canonicalTabIDs.contains)
                let following = paneTabIDs[paneTabIDs.index(after: index)...]
                    .first(where: canonicalTabIDs.contains)
                let fallbackSlot = paneTabIDs[..<index].reduce(into: 0) { count, candidate in
                    if canonicalTabIDs.contains(candidate) { count += 1 }
                }
                return TerminalBackendClientOverlayTabPlacement(
                    tabID: tabID,
                    precedingCanonicalTabID: preceding,
                    followingCanonicalTabID: following,
                    fallbackSlot: fallbackSlot
                )
            }
            let targetPaneID = canonicalPaneIDs.contains(existingPaneID)
                ? existingPaneID
                : paneTabIDs.compactMap { tabID in
                    workspace.panelIdFromSurfaceId(tabID).flatMap {
                        canonicalPaneBySurface[$0]
                    }
                }.first
            if let targetPaneID {
                overlaysByCanonicalPane[targetPaneID, default: []].append(contentsOf: overlays)
            } else {
                standaloneOverlayTabs.formUnion(overlays.map(\.tabID))
            }
        }

        let canonicalCounts = externalNodeSurfaceCounts(
            in: existingTree,
            matching: canonicalTabIDs
        )
        let canonicalExistingTree = existingCanonicalSubtree(
            in: existingTree,
            surfaceCounts: canonicalCounts
        )
        guard var canonicalNode = try makeAuthoritativeNode(
            plan.screen.layout,
            panesByID: panesByID,
            workspace: workspace,
            existing: canonicalExistingTree,
            overlayTabsByPane: &overlaysByCanonicalPane
        ) else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "canonical workspace has no projectable presentation"
            )
        }
        guard overlaysByCanonicalPane.values.allSatisfy(\.isEmpty) else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "canonical overlay placement"
            )
        }

        if let overlayNode = try extractStandaloneOverlayTree(
            existingTree,
            retainedTabs: standaloneOverlayTabs,
            workspace: workspace
        ) {
            let descriptor = overlayWrapperDescriptor(
                existingTree,
                canonicalCounts: canonicalCounts,
                overlayCounts: externalNodeSurfaceCounts(
                    in: existingTree,
                    matching: standaloneOverlayTabs
                )
            )
            let splitID = descriptor?.id ?? UUID()
            let orientation = descriptor?.orientation ?? .horizontal
            let ratio = descriptor?.ratio ?? 0.75
            if descriptor?.overlayFirst == true {
                canonicalNode = .split(BonsplitAuthoritativeTree.Split(
                    id: splitID,
                    orientation: orientation,
                    ratio: ratio,
                    first: overlayNode,
                    second: canonicalNode
                ))
            } else {
                canonicalNode = .split(BonsplitAuthoritativeTree.Split(
                    id: splitID,
                    orientation: orientation,
                    ratio: ratio,
                    first: canonicalNode,
                    second: overlayNode
                ))
            }
        }
        return BonsplitAuthoritativeTree(root: canonicalNode)
    }

    private func makeAuthoritativeNode(
        _ layout: CanonicalLayout,
        panesByID: [UUID: CanonicalPane],
        workspace: Workspace,
        existing: ExternalTreeNode?,
        overlayTabsByPane: inout [UUID: [TerminalBackendClientOverlayTabPlacement]]
    ) throws -> BonsplitAuthoritativeTree.Node? {
        switch layout {
        case .leaf(_, let paneUUID):
            guard let pane = panesByID[paneUUID.rawValue] else {
                throw TerminalBackendTopologyProjectionError.missingPane(paneUUID.rawValue)
            }
            var tabIDs = try pane.tabs.filter {
                shouldProjectCanonicalSurface($0)
            }.map { surface -> TabID in
                guard let tabID = workspace.surfaceIdFromPanelId(surface.uuid.rawValue) else {
                    throw TerminalBackendTopologyProjectionError.missingSurface(
                        surface.uuid.rawValue
                    )
                }
                return tabID
            }
            if let overlayTabs = overlayTabsByPane.removeValue(forKey: paneUUID.rawValue) {
                tabIDs = mergeClientOverlayTabs(overlayTabs, into: tabIDs)
            }
            guard !tabIDs.isEmpty else { return nil }
            return .pane(BonsplitAuthoritativeTree.Pane(
                id: Bonsplit.PaneID(id: paneUUID.rawValue),
                tabs: tabIDs
            ))

        case .split(let direction, let ratio, let first, let second):
            let existingSplit: ExternalSplitNode?
            if case .split(let split)? = existing {
                existingSplit = split
            } else {
                existingSplit = nil
            }
            let splitID = existingSplit.flatMap { UUID(uuidString: $0.id) } ?? UUID()
            let firstNode = try makeAuthoritativeNode(
                first,
                panesByID: panesByID,
                workspace: workspace,
                existing: existingSplit?.first,
                overlayTabsByPane: &overlayTabsByPane
            )
            let secondNode = try makeAuthoritativeNode(
                second,
                panesByID: panesByID,
                workspace: workspace,
                existing: existingSplit?.second,
                overlayTabsByPane: &overlayTabsByPane
            )
            switch (firstNode, secondNode) {
            case (.some(let firstNode), .some(let secondNode)):
                return .split(BonsplitAuthoritativeTree.Split(
                    id: splitID,
                    orientation: direction == .right ? .horizontal : .vertical,
                    ratio: Double(ratio),
                    first: firstNode,
                    second: secondNode
                ))
            case (.some(let node), .none), (.none, .some(let node)):
                return node
            case (.none, .none):
                return nil
            }
        }
    }

    private func mergeClientOverlayTabs(
        _ overlays: [TerminalBackendClientOverlayTabPlacement],
        into canonicalTabs: [TabID]
    ) -> [TabID] {
        var overlaysBySlot: [Int: [TabID]] = [:]
        for overlay in overlays {
            let slot: Int
            if let preceding = overlay.precedingCanonicalTabID,
               let index = canonicalTabs.firstIndex(of: preceding) {
                slot = index + 1
            } else if let following = overlay.followingCanonicalTabID,
                      let index = canonicalTabs.firstIndex(of: following) {
                slot = index
            } else {
                slot = min(max(overlay.fallbackSlot, 0), canonicalTabs.count)
            }
            overlaysBySlot[slot, default: []].append(overlay.tabID)
        }

        var merged: [TabID] = []
        merged.reserveCapacity(canonicalTabs.count + overlays.count)
        for slot in 0...canonicalTabs.count {
            merged.append(contentsOf: overlaysBySlot[slot] ?? [])
            if slot < canonicalTabs.count {
                merged.append(canonicalTabs[slot])
            }
        }
        return merged
    }

    private func existingPanes(in node: ExternalTreeNode) -> [ExternalPaneNode] {
        switch node {
        case .pane(let pane):
            [pane]
        case .split(let split):
            existingPanes(in: split.first) + existingPanes(in: split.second)
        }
    }

    private func existingCanonicalSubtree(
        in node: ExternalTreeNode,
        surfaceCounts: [String: Int]
    ) -> ExternalTreeNode {
        guard case .split(let split) = node else { return node }
        let total = surfaceCounts[externalNodeID(node), default: 0]
        let firstCount = surfaceCounts[externalNodeID(split.first), default: 0]
        let secondCount = surfaceCounts[externalNodeID(split.second), default: 0]
        if firstCount == total, secondCount == 0 {
            return existingCanonicalSubtree(
                in: split.first,
                surfaceCounts: surfaceCounts
            )
        }
        if secondCount == total, firstCount == 0 {
            return existingCanonicalSubtree(
                in: split.second,
                surfaceCounts: surfaceCounts
            )
        }
        return node
    }

    private func externalNodeSurfaceCounts(
        in node: ExternalTreeNode,
        matching tabIDs: Set<TabID>
    ) -> [String: Int] {
        var counts: [String: Int] = [:]
        func visit(_ node: ExternalTreeNode) -> Int {
            let count: Int
            switch node {
            case .pane(let pane):
                count = pane.tabs.reduce(into: 0) { count, tab in
                    if let id = UUID(uuidString: tab.id),
                       tabIDs.contains(TabID(uuid: id)) {
                        count += 1
                    }
                }
            case .split(let split):
                count = visit(split.first) + visit(split.second)
            }
            counts[externalNodeID(node)] = count
            return count
        }
        _ = visit(node)
        return counts
    }

    private func externalNodeID(_ node: ExternalTreeNode) -> String {
        switch node {
        case .pane(let pane): pane.id
        case .split(let split): split.id
        }
    }

    private func extractStandaloneOverlayTree(
        _ node: ExternalTreeNode,
        retainedTabs: Set<TabID>,
        workspace: Workspace
    ) throws -> BonsplitAuthoritativeTree.Node? {
        switch node {
        case .pane(let pane):
            guard let paneUUID = UUID(uuidString: pane.id) else {
                throw TerminalBackendTopologyProjectionError.projectionFailed(
                    "overlay pane identity is invalid"
                )
            }
            let tabs = pane.tabs.compactMap { tab -> TabID? in
                guard let id = UUID(uuidString: tab.id) else { return nil }
                let tabID = TabID(uuid: id)
                return retainedTabs.contains(tabID) ? tabID : nil
            }
            guard !tabs.isEmpty else { return nil }
            let paneID = Bonsplit.PaneID(id: paneUUID)
            let selected = pane.selectedTabId
                .flatMap { UUID(uuidString: $0) }
                .map { TabID(uuid: $0) }
                .flatMap { tabs.contains($0) ? $0 : nil }
                ?? tabs[0]
            return .pane(BonsplitAuthoritativeTree.Pane(
                id: paneID,
                tabs: tabs,
                selection: .tab(selected),
                fullWidthTabMode: .value(
                    workspace.bonsplitController.isFullWidthTabMode(inPane: paneID)
                )
            ))

        case .split(let split):
            let first = try extractStandaloneOverlayTree(
                split.first,
                retainedTabs: retainedTabs,
                workspace: workspace
            )
            let second = try extractStandaloneOverlayTree(
                split.second,
                retainedTabs: retainedTabs,
                workspace: workspace
            )
            switch (first, second) {
            case (.some(let first), .some(let second)):
                guard let splitID = UUID(uuidString: split.id) else {
                    throw TerminalBackendTopologyProjectionError.projectionFailed(
                        "overlay split identity is invalid"
                    )
                }
                return .split(BonsplitAuthoritativeTree.Split(
                    id: splitID,
                    orientation: split.orientation == "horizontal" ? .horizontal : .vertical,
                    ratio: split.dividerPosition,
                    first: first,
                    second: second
                ))
            case (.some(let first), .none):
                return first
            case (.none, .some(let second)):
                return second
            case (.none, .none):
                return nil
            }
        }
    }

    private func overlayWrapperDescriptor(
        _ node: ExternalTreeNode,
        canonicalCounts: [String: Int],
        overlayCounts: [String: Int]
    ) -> (id: UUID, orientation: SplitOrientation, ratio: Double, overlayFirst: Bool)? {
        guard case .split(let split) = node,
              let splitID = UUID(uuidString: split.id) else { return nil }
        let firstCanonical = canonicalCounts[externalNodeID(split.first), default: 0]
        let secondCanonical = canonicalCounts[externalNodeID(split.second), default: 0]
        let firstOverlay = overlayCounts[externalNodeID(split.first), default: 0]
        let secondOverlay = overlayCounts[externalNodeID(split.second), default: 0]
        let orientation: SplitOrientation = split.orientation == "horizontal"
            ? .horizontal
            : .vertical
        if firstCanonical == 0, firstOverlay > 0, secondCanonical > 0 {
            return (splitID, orientation, split.dividerPosition, true)
        }
        if secondCanonical == 0, secondOverlay > 0, firstCanonical > 0 {
            return (splitID, orientation, split.dividerPosition, false)
        }
        if firstCanonical > 0, secondCanonical == 0 {
            return overlayWrapperDescriptor(
                split.first,
                canonicalCounts: canonicalCounts,
                overlayCounts: overlayCounts
            )
        }
        if secondCanonical > 0, firstCanonical == 0 {
            return overlayWrapperDescriptor(
                split.second,
                canonicalCounts: canonicalCounts,
                overlayCounts: overlayCounts
            )
        }
        return nil
    }

    private func canonicalFirstPane(
        in layout: CanonicalLayout,
        panesByID: [UUID: CanonicalPane]
    ) throws -> CanonicalPane {
        guard let pane = try canonicalFirstProjectablePane(
            in: layout,
            panesByID: panesByID
        ) else {
            throw TerminalBackendTopologyProjectionError.projectionFailed(
                "canonical workspace has no projectable pane"
            )
        }
        return pane
    }

    private func canonicalFirstProjectablePane(
        in layout: CanonicalLayout,
        panesByID: [UUID: CanonicalPane]
    ) throws -> CanonicalPane? {
        switch layout {
        case .leaf(_, let paneUUID):
            guard let pane = panesByID[paneUUID.rawValue] else {
                throw TerminalBackendTopologyProjectionError.missingPane(paneUUID.rawValue)
            }
            return pane.tabs.contains(where: shouldProjectCanonicalSurface) ? pane : nil
        case .split(_, _, let first, let second):
            if let pane = try canonicalFirstProjectablePane(
                in: first,
                panesByID: panesByID
            ) {
                return pane
            }
            return try canonicalFirstProjectablePane(
                in: second,
                panesByID: panesByID
            )
        }
    }

    /// Native WebKit endpoints are canonical placement projected by Swift.
    /// Daemon-rendered endpoints stay in the topology but remain omitted when
    /// their descriptor explicitly permits a frontend without frame support.
    private func shouldProjectCanonicalSurface(_ surface: CanonicalSurface) -> Bool {
        guard surface.kind.lowercased() == "browser",
              surface.browserEndpoint?.frontendProjection == .frontendOptional else {
            return true
        }
        return surface.browserEndpoint?.transport == .frontendNativeV1
    }

    private func applyCanonicalSurfaceName(
        _ surface: CanonicalSurface,
        in workspace: Workspace
    ) {
        let name = surface.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = workspace.setPanelCustomTitle(
            panelId: surface.uuid.rawValue,
            title: name?.isEmpty == false ? name : nil,
            source: .backend
        )
    }

    private func panelType(for surface: CanonicalSurface) throws -> PanelType {
        switch surface.kind.lowercased() {
        case "pty", "terminal":
            .terminal
        case "browser":
            .browser
        default:
            throw TerminalBackendTopologyProjectionError.unsupportedSurfaceKind(
                surfaceID: surface.uuid.rawValue,
                kind: surface.kind
            )
        }
    }
}
