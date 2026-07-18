import CmuxTerminalBackend
import Foundation

/// A fully validated, immutable projection plan built before live Swift state changes.
struct TerminalBackendTopologyProjectionPlan: Equatable, Sendable {
    struct Workspace: Equatable, Sendable {
        let canonical: CanonicalWorkspace
        let screen: CanonicalScreen
    }

    let workspaces: [Workspace]
    let placements: Set<TerminalBackendTopologyPlacement>

    init(topology: CanonicalTopology) throws {
        var workspaces: [Workspace] = []
        var placements: Set<TerminalBackendTopologyPlacement> = []

        for workspace in topology.workspaces {
            guard workspace.screens.count == 1 else {
                throw TerminalBackendTopologyProjectionError.multipleScreens(
                    workspaceID: workspace.uuid.rawValue,
                    count: workspace.screens.count
                )
            }
            guard let screen = workspace.screens.first else {
                throw TerminalBackendTopologyProjectionError.multipleScreens(
                    workspaceID: workspace.uuid.rawValue,
                    count: 0
                )
            }
            for pane in screen.panes {
                for surface in pane.tabs {
                    guard Self.isTerminalKind(surface.kind) else {
                        throw TerminalBackendTopologyProjectionError.unsupportedSurfaceKind(
                            surfaceID: surface.uuid.rawValue,
                            kind: surface.kind
                        )
                    }
                    let placement = TerminalBackendTopologyPlacement(
                        workspaceID: workspace.uuid.rawValue,
                        surfaceID: surface.uuid.rawValue
                    )
                    guard placements.insert(placement).inserted else {
                        throw TerminalBackendTopologyProjectionError.duplicatePlacement(placement)
                    }
                }
            }
            workspaces.append(Workspace(canonical: workspace, screen: screen))
        }

        self.workspaces = workspaces
        self.placements = placements
    }

    private static func isTerminalKind(_ kind: String) -> Bool {
        switch kind.lowercased() {
        case "pty", "terminal":
            true
        default:
            false
        }
    }
}
