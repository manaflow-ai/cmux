import CmuxWorkspaces
import Foundation

/// Immutable, versioned value sampled from the Mac hierarchy on the main actor.
/// Publishers and focus notifications only request a new sample. They are never
/// treated as the state carried by an event, which avoids mixing `willSet`
/// values with later live reads from other hierarchy dimensions.
struct MobileWorkspaceHierarchyProjection {
    static let schemaVersion = 1

    struct PaneListValue: Hashable {
        let id: UUID
        let spatialIndex: Int
        let terminalIDs: [UUID]
    }

    struct PanePayloadValue: Hashable {
        let id: UUID
        let spatialIndex: Int
        let isFocused: Bool
        let terminalIDs: [UUID]
    }

    struct TerminalListValue: Hashable {
        let id: UUID
        let title: String
        let currentDirectory: String?
        let paneID: UUID?
        let canClose: Bool
        let requiresCloseConfirmation: Bool
        let isReady: Bool
    }

    struct TerminalPayloadValue: Hashable {
        let list: TerminalListValue
        let isFocused: Bool
    }

    struct SurfaceListValue: Hashable {
        let id: UUID
        let title: String?
        let reportedDirectory: String?
    }

    struct PanelDirectoryValue: Hashable {
        let id: UUID
        let directory: String?
    }

    struct ListValue: Hashable {
        let schemaVersion: Int
        let id: UUID
        let title: String
        let isPinned: Bool
        let groupID: UUID?
        let previewSignature: Int?
        let orderedPanelIDs: [UUID]
        let pinnedPanelIDs: [UUID]
        let panes: [PaneListValue]
        let terminals: [TerminalListValue]
        let surfaces: [SurfaceListValue]
        let currentDirectory: String?
        let panelDirectories: [PanelDirectoryValue]

        /// Hashes fields with an observer invalidation source. Close-confirmation
        /// fallback can change inside Ghostty without a workspace publisher, so
        /// it remains in the payload value but cannot spuriously flip list digest
        /// during an unrelated title or directory wakeup.
        func hashObserverIdentity(into hasher: inout Hasher) {
            hasher.combine(schemaVersion)
            hasher.combine(id)
            hasher.combine(title)
            hasher.combine(isPinned)
            hasher.combine(groupID)
            hasher.combine(previewSignature)
            hasher.combine(orderedPanelIDs)
            hasher.combine(pinnedPanelIDs)
            hasher.combine(panes)
            hasher.combine(terminals.count)
            for terminal in terminals {
                hasher.combine(terminal.id)
                hasher.combine(terminal.title)
                hasher.combine(terminal.currentDirectory)
                hasher.combine(terminal.paneID)
                hasher.combine(terminal.canClose)
                hasher.combine(terminal.isReady)
            }
            hasher.combine(surfaces)
            hasher.combine(currentDirectory)
            hasher.combine(panelDirectories)
        }
    }

    struct PaneFocusValue: Hashable {
        let id: UUID
        let selectedTerminalID: UUID?
    }

    struct FocusValue: Hashable {
        let schemaVersion: Int
        let workspaceID: UUID
        let focusedPaneID: UUID?
        let selectedTerminalID: UUID?
        let paneSelections: [PaneFocusValue]

        /// Samples only focus dimensions. This is the always-on focus-event hot
        /// path, so it must not touch titles, directories, pin state, or payload
        /// terminal allocation.
        @MainActor
        init(workspace: Workspace) {
            workspaceID = workspace.id
            focusedPaneID = workspace.bonsplitController.focusedPaneId?.id
            selectedTerminalID = workspace.focusedTerminalPanel?.id
            paneSelections = workspace.bonsplitController.allPaneIds.map { paneID in
                let terminalID = workspace.bonsplitController.selectedTab(inPane: paneID)
                    .flatMap { workspace.panelIdFromSurfaceId($0.id) }
                    .flatMap { workspace.terminalPanel(for: $0)?.id }
                return PaneFocusValue(id: paneID.id, selectedTerminalID: terminalID)
            }
            schemaVersion = MobileWorkspaceHierarchyProjection.schemaVersion
        }

        var eventPayload: [String: Any] {
            [
                "kind": "focus",
                "workspace_id": workspaceID.uuidString,
                "focused_pane_id": focusedPaneID?.uuidString ?? NSNull(),
                "selected_terminal_id": selectedTerminalID?.uuidString ?? NSNull(),
            ]
        }
    }

    let list: ListValue
    let focus: FocusValue
    let panes: [PanePayloadValue]
    let terminals: [TerminalPayloadValue]

    @MainActor
    init(workspace: Workspace, previewSignature: Int? = nil) {
        let focusValue = FocusValue(workspace: workspace)
        let paneIDs = workspace.bonsplitController.allPaneIds
        var paneIDByTerminalID: [UUID: UUID] = [:]
        var paneListValues: [PaneListValue] = []
        var panePayloadValues: [PanePayloadValue] = []
        for (spatialIndex, paneID) in paneIDs.enumerated() {
            let terminalIDs = workspace.bonsplitController.tabs(inPane: paneID).compactMap { tab -> UUID? in
                guard let panelID = workspace.panelIdFromSurfaceId(tab.id),
                      workspace.terminalPanel(for: panelID) != nil else {
                    return nil
                }
                paneIDByTerminalID[panelID] = paneID.id
                return panelID
            }
            paneListValues.append(.init(id: paneID.id, spatialIndex: spatialIndex, terminalIDs: terminalIDs))
            panePayloadValues.append(.init(
                id: paneID.id,
                spatialIndex: spatialIndex,
                isFocused: paneID.id == focusValue.focusedPaneID,
                terminalIDs: terminalIDs
            ))
        }

        let orderedPanelIDs = workspace.orderedPanelIds
        let terminalValues = orderedPanelIDs.compactMap { panelID -> TerminalPayloadValue? in
            guard let terminal = workspace.terminalPanel(for: panelID) else { return nil }
            let localDirectory = [terminal.directory, terminal.requestedWorkingDirectory]
                .compactMap { raw -> String? in
                    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    return raw
                }
                .first
            let directory = workspace.effectivePanelDirectory(
                panelId: terminal.id,
                localFallback: localDirectory
            )
            return .init(
                list: .init(
                    id: terminal.id,
                    title: workspace.panelTitle(panelId: terminal.id) ?? terminal.displayTitle,
                    currentDirectory: directory,
                    paneID: paneIDByTerminalID[terminal.id],
                    canClose: workspace.panels.count > 1 && !workspace.pinnedPanelIds.contains(terminal.id),
                    requiresCloseConfirmation: workspace.panelNeedsConfirmClose(panelId: terminal.id),
                    isReady: terminal.surface.surface != nil
                ),
                isFocused: terminal.id == workspace.focusedPanelId
            )
        }
        let surfaces = orderedPanelIDs.map {
            SurfaceListValue(
                id: $0,
                title: workspace.panelTitle(panelId: $0),
                reportedDirectory: workspace.reportedPanelDirectory(panelId: $0)
            )
        }
        let panelDirectories = workspace.panelDirectories.keys
            .sorted { $0.uuidString < $1.uuidString }
            .map { PanelDirectoryValue(id: $0, directory: workspace.panelDirectories[$0]) }
        list = .init(
            schemaVersion: Self.schemaVersion,
            id: workspace.id,
            title: workspace.title,
            isPinned: workspace.isPinned,
            groupID: workspace.groupId,
            previewSignature: previewSignature,
            orderedPanelIDs: orderedPanelIDs,
            pinnedPanelIDs: workspace.pinnedPanelIds.sorted { $0.uuidString < $1.uuidString },
            panes: paneListValues,
            terminals: terminalValues.map(\.list),
            surfaces: surfaces,
            currentDirectory: workspace.presentedCurrentDirectory,
            panelDirectories: panelDirectories
        )
        focus = focusValue
        panes = panePayloadValues
        terminals = terminalValues
    }
}

struct MobileWorkspaceListProjection: Hashable {
    struct GroupValue: Hashable {
        let id: UUID
        let name: String
        let isCollapsed: Bool
        let isPinned: Bool
        let anchorWorkspaceID: UUID?
    }

    let schemaVersion: Int
    let selectedTabID: UUID?
    let groups: [GroupValue]
    let workspaces: [MobileWorkspaceHierarchyProjection.ListValue]

    @MainActor
    init(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int]
    ) {
        schemaVersion = MobileWorkspaceHierarchyProjection.schemaVersion
        self.selectedTabID = selectedTabID
        self.groups = groups.map {
            .init(
                id: $0.id,
                name: $0.name,
                isCollapsed: $0.isCollapsed,
                isPinned: $0.isPinned,
                anchorWorkspaceID: $0.anchorWorkspaceId
            )
        }
        workspaces = tabs.map {
            MobileWorkspaceHierarchyProjection(
                workspace: $0,
                previewSignature: previewSignatures[$0.id]
            ).list
        }
    }

    /// Computes the list identity without retaining arrays for the previous
    /// snapshot. Each workspace value is hashed and released before sampling the
    /// next workspace.
    @MainActor
    static func digest(
        tabs: [Workspace],
        groups: [WorkspaceGroup],
        selectedTabID: UUID?,
        previewSignatures: [UUID: Int]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(MobileWorkspaceHierarchyProjection.schemaVersion)
        hasher.combine(selectedTabID)
        hasher.combine(groups.count)
        for group in groups {
            hasher.combine(GroupValue(
                id: group.id,
                name: group.name,
                isCollapsed: group.isCollapsed,
                isPinned: group.isPinned,
                anchorWorkspaceID: group.anchorWorkspaceId
            ))
        }
        hasher.combine(tabs.count)
        for workspace in tabs {
            let list = MobileWorkspaceHierarchyProjection(
                workspace: workspace,
                previewSignature: previewSignatures[workspace.id]
            ).list
            list.hashObserverIdentity(into: &hasher)
        }
        return hasher.finalize()
    }
}
