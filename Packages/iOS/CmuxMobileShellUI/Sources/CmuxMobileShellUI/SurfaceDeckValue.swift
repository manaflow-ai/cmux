import CmuxMobileShellModel

/// Immutable workspace surface state rendered by ``SurfaceDeckBar``.
struct SurfaceDeckValue: Equatable {
    /// One pane's ordered surface chips.
    struct PaneGroup: Identifiable, Equatable {
        let id: String
        let number: Int
        let totalCount: Int
        let chips: [Chip]
    }

    /// One surface chip in a pane group.
    struct Chip: Identifiable, Equatable {
        let id: String
        let title: String
        let type: MobilePaneSurfaceType

        var isTerminal: Bool { type.isTerminal }
    }

    let groups: [PaneGroup]
    let selectedSurfaceID: String?
    let agentStateKindsBySurfaceID: [String: ChatAgentStateKind]
    let canCreateWorkspace: Bool
    let showsPaneMap: Bool

    init(
        workspace: MobileWorkspacePreview,
        selectedSurfaceID: String?,
        agentStateKindsBySurfaceID: [String: ChatAgentStateKind],
        canCreateWorkspace: Bool
    ) {
        if let layout = workspace.layout {
            let panes = layout.orderedPanes
            groups = panes.enumerated().map { index, pane in
                PaneGroup(
                    id: pane.id,
                    number: index + 1,
                    totalCount: panes.count,
                    chips: pane.surfaces.map { surface in
                        Chip(id: surface.id, title: surface.title, type: surface.type)
                    }
                )
            }
        } else {
            groups = [
                PaneGroup(
                    id: workspace.id.rawValue,
                    number: 1,
                    totalCount: 1,
                    chips: workspace.terminals.map { terminal in
                        Chip(id: terminal.id.rawValue, title: terminal.name, type: .terminal)
                    }
                ),
            ]
        }
        self.selectedSurfaceID = selectedSurfaceID
        self.agentStateKindsBySurfaceID = agentStateKindsBySurfaceID
        self.canCreateWorkspace = canCreateWorkspace
        showsPaneMap = workspace.layout != nil
    }

    /// The deck owns the only in-workspace creation controls, so it remains
    /// visible even when the workspace has zero or one terminal.
    var shouldShow: Bool {
        true
    }
}
