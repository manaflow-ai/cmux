import CmuxMobileShellModel

/// Immutable workspace surface state rendered by ``SurfaceDeckBar``.
struct SurfaceDeckValue: Equatable {
    /// One pane's ordered surface chips.
    struct PaneGroup: Identifiable, Equatable {
        let id: String
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
            groups = layout.orderedPanes.map { pane in
                PaneGroup(
                    id: pane.id,
                    chips: pane.surfaces.map { surface in
                        Chip(id: surface.id, title: surface.title, type: surface.type)
                    }
                )
            }
        } else {
            groups = [
                PaneGroup(
                    id: workspace.id.rawValue,
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

    var shouldShow: Bool {
        let surfaceCount = groups.reduce(into: 0) { count, group in
            count += group.chips.count
        }
        return surfaceCount > 1 || groups.count > 1
    }
}
